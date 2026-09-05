RSpec.describe Routing::Constraints do
  BANKS = ['sberbank','alfa','tinkoff','vtb','raiffeisen','gazprombank'].freeze
  def self.orig(amount, bank, prs)
    prs.select do |p|
      next false if p['status'] != 'active'
      next false if p['traffic_percentage'].to_f.zero? && p['payment_system'] != 'spacepayments'
      next false if p['limit_amount_min'] && amount< p['limit_amount_min']
      next false if p['limit_amount_max'] && amount > p['limit_amount_max']
      next false if p['daily_amount_limit'] && (p['daily_approved_amount'].to_f + amount)> p['daily_amount_limit']
      next false if p['in_progress_count_limit'] && (p['in_progress_count'].to_i + 1) > p['in_progress_count_limit']
      next false if p['in_progress_amount_limit'] && (p['in_progress_amount'].to_f + amount) > p['in_progress_amount_limit']
      next false if p['available_requisites'].to_i.zero?
      next false if p['provider_margin_pct'].to_f > p['merchant_margin_pct'].to_f && !p['allow_negative_agreement']
      bnk = p['banks'] || []
      if bnk.any?
        if p['exclude_banks']
          next false if bnk.include?(bank)
        else
          next false unless bnk.include?(bank)
        end
      end
      true
    end.map { |p| p['payment_system'] }
  end
  let(:con) { described_class.new }
  let(:prs) { Fix.prov }
  let(:ref) { Fix.json('reference_decisions.json') }
  let(:base) do
    {'payment_system'=>'x','status'=>'active','traffic_percentage'=>10,'available_requisites'=>5,'provider_margin_pct'=>1.0,'merchant_margin_pct'=>1.5,'in_progress_count'=>0,'in_progress_amount'=>0,'daily_approved_amount'=>0}
  end
  describe 'эталон организаторов' do
    it 'воспроизводит все списки подходящих провайдеров' do
      Fix.queue.each do |op|
        got = con.pass(prs, op).map(&:name).reject { |n| n == 'spacepayments' }
        expect(got).to eq(ref['eligible_providers'][op.id])
      end
    end
    it 'воспроизводит все ожидаемые пропуски' do
      ref['skip_reasons_expected'].each do |oid, sks|
        op = Fix.queue.find { |o| o.id == oid }
        sks.each do |pnm, exp|
          got = con.deny(prs.find { |p| p.name == pnm }, op)
          expect(got && got['reason']).to eq(exp)
        end
      end
    end
  end
  describe 'эквивалентность функции' do
    it 'совпадает на 600 случайных заявках' do
      raw =Fix.json('providers.json')['providers']
      bad= []
      srand(20260730)
      600.times do |i|
        amt = [100, 500, 800, 999, 1000, 1001, 15_000, 49_999, 50_000, 50_001, 100_000, 100_001, 200_000, 500_000].sample
        bnk = BANKS.sample
        got = con.pass(Routing::Models::Provider.list(raw), Fix.oper(amt, bnk, "r#{i}")).map(&:name)
        exp = self.class.orig(amt, bnk, raw)
        bad << "#{amt} #{bnk}" unless got == exp
      end
      expect(bad).to be_empty
    end
    it 'совпадает на подменённых состояниях провайдеров' do
      bad = []
      srand(1)
      200.times do |i|
        raw= Fix.json('providers.json')['providers'].map do |p|
          p.merge('status' => ['active', 'active', 'disabled'].sample,
                  'available_requisites' => [0, 1, 5].sample,
                  'traffic_percentage' => [0, 25, 40].sample,
                  'daily_approved_amount' => [0, 2_900_000, 4_999_999].sample)
        end
        amt= [800, 15_000, 60_000, 150_000].sample
        bnk= BANKS.sample
        got = con.pass(Routing::Models::Provider.list(raw), Fix.oper(amt, bnk, "m#{i}")).map(&:name)
        bad << "#{amt} #{bnk}" unless got == self.class.orig(amt, bnk, raw)
      end
      expect(bad).to be_empty
    end
  end
  describe 'порядок правил' do
    let(:allbad) do
      {'payment_system'=>'x','status'=>'disabled','traffic_percentage'=>0,
       'limit_amount_min'=>200_000,'limit_amount_max'=>1000,
       'daily_amount_limit'=>1,'daily_approved_amount'=>1,
       'in_progress_count_limit'=>0,'in_progress_count'=>5,
       'in_progress_amount_limit'=>1,'in_progress_amount'=>1,
       'available_requisites'=>0,'provider_margin_pct'=>2.0,'merchant_margin_pct'=>1.0,
       'banks'=>['alfa'],'requests_minut'=>0}
    end
    let(:steps) do
      [['provider_inactive', {}],
       ['traffic_disabled', {'status'=>'active'}],
       ['amount_below_minimum', {'traffic_percentage'=>10}],
       ['amount_exceeds_limit', {'limit_amount_min'=>nil}],
       ['daily_limit_exceeded', {'limit_amount_max'=>nil}],
       ['in_progress_count_exceeded', {'daily_amount_limit'=>nil}],
       ['in_progress_amount_exceeded', {'in_progress_count_limit'=>nil}],
       ['no_available_requisites', {'in_progress_amount_limit'=>nil}],
       ['negative_margin', {'available_requisites'=>5}],
       ['bank_not_in_list', {'provider_margin_pct'=>1.0}],
       ['rate_limi', {'banks'=>[]}]]
    end
    it 'выдаёт причины строго в порядке правил когда нарушено всё' do
      cur= allbad
      got = []
      steps.each do |_, pat|
        cur= cur.merge(pat)
        prv = Routing::Models::Provider.new(cur)
        prv.hold(1, 990)
        res = con.deny(prv, Fix.oper(150_000, 'sberbank'), 1000)
        got << (res && res['reason'])
      end
      expect(got).to eq(steps.map(&:first))
    end
    it 'сумма ниже мин важнее банка когда отказывают оба' do
      got = con.deny(prs.find { |p| p.name == 'vipay'}, Fix.oper(800, 'alfa'))
      expect(got['reason']).to eq('amount_below_minimum')
    end
    it 'сумма выше макс важнее банка когда отказывают оба' do
      got = con.deny(prs.find { |p| p.name == 'payflow' }, Fix.oper(150_000, 'vtb'))
      expect(got['reason']).to eq('amount_exceeds_limit')
    end
  end
  describe 'каждое правило срабатывает' do
    {
      'provider_inactive' => {'status'=>'disabled'},
      'traffic_disabled' => {'traffic_percentage'=>0},
      'amount_below_minimum' => {'limit_amount_min'=>200_000},
      'amount_exceeds_limit' => {'limit_amount_max'=>100_000},
      'daily_limit_exceeded' => {'daily_amount_limit'=>5000},
      'in_progress_count_exceeded' => {'in_progress_count_limit'=>0},
      'in_progress_amount_exceeded' => {'in_progress_amount_limit'=>5000},
      'no_available_requisites' => {'available_requisites'=>0},
      'negative_margin' => {'provider_margin_pct'=>2.0},
      'bank_not_in_list' => {'banks'=>['alfa']},
      'bank_excluded' => {'banks'=>['sberbank'],'exclude_banks'=>true}
    }.each do |cod, pat|
      it cod do
        got = con.deny(Routing::Models::Provider.new(base.merge(pat)), Fix.oper(150_000, 'sberbank'))
        expect(got && got['reason']).to eq(cod)
        expect(got['details']).not_to be_empty
      end
    end
    it 'rate_limi' do
      prv = Routing::Models::Provider.new(base.merge('requests_minut' => 1))
      prv.hold(1, 990)
      expect(con.deny(prv, Fix.oper(150_000, 'sberbank'), 1000)['reason']).to eq('rate_limi')
    end
  end
  describe 'провайдер проходит когда должен' do
    {
      'self-провайдер с нулевым трафиком' => {'payment_system'=>'spacepayments','traffic_percentage'=>0},
      'отрицательная маржа при allow_negative_agreement' => {'provider_margin_pct'=>2.0,'allow_negative_agreement'=>true},
      'пустой список банков' => {'banks'=>[]},
      'exclude_banks когда банка нет в списке' => {'banks'=>['alfa'],'exclude_banks'=>true},
      'все лимиты null' => {'limit_amount_min'=>nil,'limit_amount_max'=>nil,'daily_amount_limit'=>nil}
    }.each do |lbl, pat|
      it lbl do
        expect(con.deny(Routing::Models::Provider.new(base.merge(pat)), Fix.oper(150_000, 'sberbank'))).to be_nil
      end
    end
  end
end
