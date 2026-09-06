RSpec.describe Routing::Reporter do
  let(:cfg) { Routing::Config.load(File.join(ROOTDIR, 'config', 'strategy.yml')) }
  let(:his) { Fix.hist }
  let(:ops) { Fix.queue }
  let(:dec) do
    prs = Fix.prov
    Routing::Router.new(prs, Routing::Constraints.new(cfg.win),
                        Routing::Scoring.new(cfg.sco, his), Routing::Simulator.new(cfg.sim)).run(ops)
  end
  let(:rep) { described_class.new(Fix.prov, his, cfg.sco).make(dec, ops, '2026-07-30') }
  describe 'обязательные поля из ТЗ' do
    it 'все на месте' do
      expect(rep.keys).to include('period', 'total_operations', 'distribution',
                                  'skip_reasons', 'projected_daily_utilization', 'recommendations')
    end
    it 'период и число операций совпадают с прогоном' do
      expect(rep['period']).to eq('2026-07-30')
      expect(rep['total_operations']).to eq(dec.size)
    end
    it 'падает на пустых решениях' do
      expect { described_class.new(Fix.prov, his, cfg.sco).make([], ops) }.to raise_error(ArgumentError)
    end
  end
  describe 'распределение' do
    it 'доли в сумме дают сто процентов' do
      expect(rep['distribution'].values.sum { |d| d['share_pct'] }).to be_within(0.1).of(100.0)
    end
    it 'количество совпадает с решениями' do
      cnt = dec.map { |d| d['selected_provider'] }.tally
      rep['distribution'].each { |nam, d| expect(d['count']).to eq(cnt[nam].to_i) }
    end
    it 'отклонение равно разнице факта и цели' do
      rep['distribution'].each_value { |d| expect(d['deviation_pp']).to be_within(0.1).of(d['share_pct'] - d['target_pct']) }
    end
    it 'считает объём в рублях' do
      sum = ops.to_h { |o| [o.id, o.amt] }
      dec.group_by { |d| d['selected_provider'] }.each do |nam, grp|
        expect(rep['distribution'][nam]['volume']).to eq(grp.sum { |d| sum[d['operation_id']] }.round)
      end
    end
  end
  describe 'причины отказа' do
    it 'в skip_reasons только жёсткие ограничения' do
      expect(rep['skip_reasons'].keys & described_class::SOFT).to be_empty
    end
    it 'мягкие причины лежат отдельно' do
      expect(rep['not_selected_reasons'].keys - described_class::SOFT).to be_empty
    end
    it 'разбивка по провайдерам не пуста' do
      expect(rep['skip_reasons_by_provider']).not_to be_empty
    end
  end
  describe 'успешность по провайдерам' do
    it 'сумма по провайдерам равна числу решений' do
      expect(rep['outcomes_by_provider'].values.sum { |o| o['total'] }).to eq(dec.size)
    end
    it 'исходы каждого провайдера складываются в его итог' do
      rep['outcomes_by_provider'].each_value do |o|
        expect(o['approved'] + o['rejected'] + o['expired']).to eq(o['total'])
      end
    end
  end
  describe 'утилизация лимитов' do
    it 'не превышает сто процентов' do
      rep['projected_daily_utilization'].each_value do |u|
        next if u['utilization_pct'].nil?
        expect(u['utilization_pct']).to be <= 100.0
      end
    end
    it 'использовано равно старту плюс добавленному очередью' do
      rep['projected_daily_utilization'].each_value { |u| expect(u['used']).to eq(u['start'] + u['added_by_queue']) }
    end
  end
  describe 'калибровка конверсии' do
    it 'сравнивает заявленное с фактическим по каждому внешнему провайдеру' do
      expect(rep['conversion_calibration'].keys).to match_array(Fix.prov.reject(&:own?).map(&:name))
    end
    it 'ловит завышене payflow' do
      expect(rep['conversion_calibration']['payflow']['gap']).to be < -0.2
    end
  end
  describe 'недостижимые цели' do
    it 'помечает payflow из-за остатка дневного лимита' do
      unr = rep['unreachable_targets'].find { |u| u['provider'] == 'payflow' }
      expect(unr['reason']).to eq('daily_limit_headroom')
      expect(unr['reachable_pct']).to be < unr['target_pct']
    end
    it 'молчит когда лимиты просторные' do
      big = Fix.json('providers.json')['providers'].map { |p| p.merge('daily_amount_limit'=>99_000_000, 'daily_approved_amount'=>0) }
      out = described_class.new(Routing::Models::Provider.list(big), his, cfg.sco).make(dec, ops)
      expect(out['unreachable_targets']).to be_empty
    end
  end
  describe 'рекомендации' do
    it 'не пусты и каждая имеет текст' do
      expect(rep['recommendations']).not_to be_empty
      rep['recommendations'].each { |m| expect(m.to_s.strip).not_to be_empty }
    end
    it 'детальные несут код, параметр и доказательство' do
      rep['recommendations_detailed'].each do |t|
        expect(t['code'].to_s).not_to be_empty
        expect(t['evidence'].to_s).not_to be_empty
      end
    end
    it 'списки строк и объектов одной длины' do
      expect(rep['recommendations'].size).to eq(rep['recommendations_detailed'].size)
    end
  end
end
