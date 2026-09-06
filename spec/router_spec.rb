RSpec.describe Routing::Router do
  let(:cfg) { Routing::Config.load(File.join(ROOTDIR, 'config', 'strategy.yml')) }
  let(:his) { Fix.hist }
  let(:ops) { Fix.queue }
  def build(raw = nil)
    prs = raw ? Routing::Models::Provider.list(raw) : Fix.prov
    [prs, described_class.new(prs, Routing::Constraints.new(cfg.win),
                              Routing::Scoring.new(cfg.sco, his), Routing::Simulator.new(cfg.sim))]
  end
  def dense(num, gap, amt = 15_000, bnk = 'alfa')
    base = Time.parse('2026-07-30T09:00:00+03:00').to_i
    Routing::Models::Operation.list((0...num).map do |i|
      {'operation_id'=>"d_#{i}",'amount'=>amt,'bank'=>bnk,'created_at'=>Time.at(base+i*gap).iso8601}
    end)
  end
  describe 'покрытие очереди' do
    it 'выдаёт решение на каждую заявку' do
      _, rtr = build
      dec = rtr.run(ops)
      expect(dec.map { |d| d['operation_id'] }).to eq(ops.map(&:id))
    end
    it 'падает на пустой очереди' do
      _, rtr = build
      expect { rtr.run([]) }.to raise_error(ArgumentError)
    end
  end
  describe 'структура решения' do
    it 'содержит обязательные поля' do
      _, rtr = build
      rtr.run(ops).each do |d|
        expect(d.keys).to include('operation_id', 'selected_provider', 'attempts', 'simulated_result', 'latency_sec')
        expect(d['attempts'].count { |a| a['decision'] == 'selected' }).to eq(1)
      end
    end
    it 'перечисляет всех провайдеров в попытках' do
      prs, rtr = build
      rtr.run(ops).each { |d| expect(d['attempts'].map { |a| a['provider'] }).to match_array(prs.map(&:name)) }
    end
    it 'нумерует шаги подряд с единицы' do
      _, rtr = build
      rtr.run(ops).each { |d| expect(d['attempts'].map { |a| a['step'] }).to eq((1..d['attempts'].size).to_a) }
    end
    it 'ставит выбранного после отсеянных и отказавших' do
      _, rtr = build
      rtr.run(ops).each do |d|
        sel = d['attempts'].index { |a| a['decision'] == 'selected' }
        dcl = d['attempts'].each_index.select { |i| d['attempts'][i]['reason'] == 'declined_by_provider' }
        expect(dcl).to all(be < sel)
      end
    end
  end
  describe 'детерминизм' do
    it 'два прогона на одном зерне дают одно и то же' do
      _, one = build
      _, two = build
      expect(one.run(ops)).to eq(two.run(ops))
    end
    it 'другое зерно меняет исходы' do
      prs = Fix.prov
      alt = described_class.new(prs, Routing::Constraints.new(cfg.win),
                                Routing::Scoring.new(cfg.sco, his), Routing::Simulator.new('seed'=>1))
      _, base = build
      expect(alt.run(ops).map { |d| d['simulated_result'] }).not_to eq(base.run(ops).map { |d| d['simulated_result'] })
    end
  end
  describe 'состояние провайдеров' do
    it 'не превышает дневной лимит' do
      prs, rtr = build
      rtr.run(dense(40, 30, 40_000, 'alfa'))
      prs.each do |p|
        lim = p.num('daily_amount_limit')
        next if lim.nil?
        expect(p['daily_approved_amount']).to be <= lim
      end
    end
    it 'освобождает занятое к концу прогона' do
      prs, rtr = build
      rtr.run(ops)
      prs.each { |p| expect(p['in_progress_amount']).to be <= p.to_h['in_progress_amount'] + 1 }
    end
    it 'считает долю по фактически принявшему провайдеру' do
      _, rtr = build
      dec = rtr.run(ops)
      expect(rtr.stat['counts']).to eq(dec.map { |d| d['selected_provider'] }.tally)
    end
  end
  describe 'плотная очередь' do
    it 'не сваливает заявки на self-провайдера при одинаковых метках времени' do
      _, rtr = build
      dec = rtr.run(dense(30, 0))
      expect(dec.count { |d| d['selected_provider'] == Routing::Models::Provider::SELFPROVIDER }).to eq(0)
    end
    it 'помечает решения принятые после ослабления' do
      _, rtr = build
      dec = rtr.run(dense(30, 0))
      rlx = dec.count { |d| d['attempts'].any? { |a| a['reason'] == 'relaxed_internal_limits' } }
      expect(rlx).to be > 0
    end
  end
  describe 'битые заявки' do
    it 'не роняют прогон и помечаются отдельной причиной' do
      raw = Fix.json('operations_queue_10.json')
      raw[3]['amount'] = 0
      dec = build.last.run(Routing::Models::Operation.list(raw))
      expect(dec.size).to eq(10)
      expect(dec.any? { |d| d['attempts'].any? { |a| a['reason'] == 'invalid_operation' } }).to be true
    end
  end
  describe 'fallback' do
    it 'уходит на self-провайдера когда внешних нет' do
      _, rtr = build
      dec = rtr.run(Routing::Models::Operation.list([{'operation_id'=>'z','amount'=>800,'bank'=>'vtb'}]))
      expect(dec.first['selected_provider']).to eq(Routing::Models::Provider::SELFPROVIDER)
    end
    it 'называет отдельную причину когда self-провайдера нет' do
      raw = Fix.json('providers.json')['providers'].reject { |p| p['payment_system'] == Routing::Models::Provider::SELFPROVIDER }
      dec = build(raw).last.run(Routing::Models::Operation.list([{'operation_id'=>'z','amount'=>800,'bank'=>'vtb'}]))
      sel = dec.first['attempts'].find { |a| a['decision'] == 'selected' }
      expect(sel['reason']).to eq('no_provider_available')
    end
  end
  describe 'сквозная проверка' do
    it 'результат проходит валидатор организаторов' do
      _, rtr = build
      out = File.join(ROOTDIR, 'out', 'spec_decisions.json')
      File.write(out, JSON.pretty_generate(rtr.run(ops)))
      ok = system("ruby #{File.join(ROOTDIR, 'scripts', 'validate_10.rb')} #{out}", out: File::NULL, err: File::NULL)
      File.delete(out)
      expect(ok).to be true
    end
  end
end
