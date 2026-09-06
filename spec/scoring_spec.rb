RSpec.describe Routing::Scoring do
  let(:cfg) { Routing::Config.load(File.join(ROOTDIR, 'config', 'strategy.yml')) }
  let(:his) { Fix.hist }
  let(:prs) { Fix.prov }
  let(:ext) { prs.reject(&:own?) }
  let(:sco) { described_class.new(cfg.sco, his) }
  let(:op) { Fix.oper(15_000, 'sberbank') }
  let(:ctx) { {'pool'=>ext,'live'=>ext,'total'=>0,'volume'=>0,'counts'=>{},'vols'=>{},'scarce'=>{}} }
  describe 'сигналы' do
    it 'все восемь присутствуют' do
      expect(sco.calc(ext.first, op, ctx)['signals'].keys).to match_array(described_class::SIGNALS)
    end
    it 'все лежат в диапазоне 0..1' do
      ext.each do |p|
        sco.calc(p, op, ctx)['signals'].each do |nam, val|
          expect(val).to be_between(0.0, 1.0), "#{p.name}/#{nam} = #{val}"
        end
      end
    end
    it 'сумма взвешенных вкладов равна итоговой оценке' do
      ext.each do |p|
        res = sco.calc(p, op, ctx)
        expect(res['weighted'].values.sum).to be_within(0.001).of(res['score'])
      end
    end
    it 'обрезает выход за границы' do
      big = Routing::Models::Provider.new(prs.first.to_h.merge('conversion_24h'=>5.0))
      expect(sco.calc(big, op, ctx)['signals']['conv']).to be <= 1.0
    end
  end
  describe 'конверсия смешивает заявленное с фактическим' do
    it 'без истории отдаёт заявленное' do
      bare = described_class.new(cfg.sco, nil)
      pay = ext.find { |p| p.name == 'payflow' }
      expect(bare.calc(pay, op, ctx)['signals']['conv']).to eq(pay.num('conversion_24h'))
    end
    it 'с историей уходит от заявленного к факту' do
      pay = ext.find { |p| p.name == 'payflow' }
      expect(sco.calc(pay, op, ctx)['signals']['conv']).to be < pay.num('conversion_24h')
    end
  end
  describe 'доля по кол-ву перенормирует цели на доступный состав' do
    it 'при полном составе делит на сто' do
      two = {'pool'=>ext,'live'=>ext,'total'=>10,'volume'=>1.0,'counts'=>{'vipay'=>4},'vols'=>{},'scarce'=>{}}
      vip = ext.find { |p| p.name == 'vipay' }
      expect(sco.calc(vip, op, two)['signals']['cnts']).to be_within(0.001).of(0.5)
    end
    it 'при выпадении провайдера цели растут у оставшихся' do
      liv = ext.reject { |p| p.name == 'vipay' }
      cut = {'pool'=>liv,'live'=>liv,'total'=>60,'volume'=>1.0,'counts'=>{'payflow'=>35,'quickpay'=>25},'vols'=>{},'scarce'=>{}}
      liv.each { |p| expect(sco.calc(p, op, cut)['signals']['cnts']).to be_within(0.01).of(0.5) }
    end
  end
  describe 'обязательный дневной оборот следит за обязательствами' do
    it 'нейтрален когда минимум набран' do
      pay = ext.find { |p| p.name == 'payflow' }
      expect(sco.calc(pay, op, ctx)['signals']['turn']).to eq(0.5)
    end
    it 'растёт при недоборе минимума' do
      low = described_class.new(cfg.sco.merge('overrides'=>{'payflow'=>{'daily_turnover_min'=>4_000_000}}), his)
      pay = ext.find { |p| p.name == 'payflow' }
      expect(low.calc(pay, op, ctx)['signals']['turn']).to be > 0.5
    end
    it 'обнуляется при превышении максимума' do
      cap = described_class.new(cfg.sco.merge('overrides'=>{'vipay'=>{'daily_turnover_max'=>3_000_000}}), his)
      vip = ext.find { |p| p.name == 'vipay' }
      expect(cap.calc(vip, op, ctx)['signals']['turn']).to eq(0.0)
    end
  end
  describe 'диапозон суммы чека не наказывает незнакомого провайдера' do
    it 'даёт ненулевую оценку тому, кого нет в списке предпочтений' do
      new = Routing::Models::Provider.new(prs.first.to_h.merge('payment_system'=>'newpay'))
      expect(sco.calc(new, op, ctx)['signals']['band']).to be > 0.0
    end
  end
  describe 'keep' do
    it 'нейтрален когда выбора нет' do
      one = {'pool'=>[ext.first],'live'=>ext,'total'=>0,'volume'=>0,'counts'=>{},'vols'=>{},'scarce'=>{ext.first.name=>1.0}}
      expect(sco.calc(ext.first, op, one)['signals']['keep']).to eq(1.0)
    end
    it 'штрафует дефицитного когда альтернатива есть' do
      scr = ctx.merge('scarce'=>{ext.first.name=>0.8})
      expect(sco.calc(ext.first, op, scr)['signals']['keep']).to be_within(0.001).of(0.2)
    end
  end
  describe 'pick' do
    it 'на пустом пуле возвращает причину отсутствия кандидатов' do
      res = sco.pick([], op, ctx)
      expect(res['winner']).to be_nil
      expect(res['reason']).to eq('no_eligible_providers')
    end
    it 'на одном кандидате говорит что выбора не было' do
      expect(sco.pick([ext.first], op, ctx)['reason']).to eq('only_eligible_provider')
    end
    it 'на нескольких выбирает лучшую оценку' do
      res = sco.pick(ext, op, ctx)
      expect(res['reason']).to eq('best_score')
      top = ext.max_by { |p| sco.calc(p, op, ctx)['score'] }
      expect(res['winner'].name).to eq(top.name)
    end
    it 'фиксирует вырожденный случай когда все оценки равны' do
      zero = described_class.new(cfg.sco.merge('weights'=>described_class::SIGNALS.to_h { |s| [s, 0.0] }), his)
      expect(zero.pick(ext, op, ctx)['reason']).to eq('all_scores_equal')
    end
    it 'ранжирует всех кандидатов по убыванию' do
      rnk = sco.pick(ext, op, ctx)['ranked'].map { |_, r| r['score'] }
      expect(rnk).to eq(rnk.sort.reverse)
    end
  end
  describe 'dcsv' do
    it 'называет сигнал с наибольшим отрывом от второго места' do
      res = sco.pick(ext, op, ctx)
      rnk = res['ranked'].to_h { |p, r| [p.name, r] }
      expect(described_class::SIGNALS).to include(sco.dcsv(rnk, res['winner'].name))
    end
    it 'молчит когда сравнивать не с кем' do
      res = sco.pick([ext.first], op, ctx)
      rnk = res['ranked'].to_h { |p, r| [p.name, r] }
      expect(sco.dcsv(rnk, ext.first.name)).to be_nil
    end
  end
end
