require 'json'
module Val
  BASE=File.expand_path('..', __dir__)
  SELF= 'spacepayments'.freeze
  def self.orig(raw, bank, prs)
    amount = Float(raw, exception: false)||0.0
    fit = prs.select do |p|
      next false if p['status'] != 'active'
      next false if p['traffic_percentage'].to_f.zero? && p['payment_system'] != SELF
      next false if p['limit_amount_min'] && amount < p['limit_amount_min']
      next false if p['limit_amount_max'] && amount > p['limit_amount_max']
      next false if p['daily_amount_limit'] && (p['daily_approved_amount'].to_f + amount) > p['daily_amount_limit']
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
    end
    fit.map { |p| p['payment_system'] }
  end
  def self.read(pth)
    abort "ошибка файл не найден #{pth}" unless File.file?(pth.to_s)
    JSON.parse(File.read(pth))
  rescue JSON::ParserError => e
    abort "ошибка невалидный JSON #{pth} #{e.message}"
  end
  def self.form(dec)
    err = []
    dec.each do |d|
      oid = d['operation_id'] || '?'
      ['operation_id', 'selected_provider', 'attempts'].each { |k| err << "#{oid} нет поля #{k}" unless d.key?(k) }
      next unless d['attempts'].is_a?(Array)
      d['attempts'].each_with_index do |a, i|
        ['provider', 'decision', 'reason'].each { |k| err << "#{oid} attempts[#{i}] нет #{k}" unless a.key?(k) }
        err << "#{oid} attempts[#{i}] decision #{a['decision'].inspect}" unless ['selected', 'skipped'].include?(a['decision'])
      end
      err << "#{oid} нет attempts с decision selected" unless d['attempts'].any? { |a| a['decision'] == 'selected' }
    end
    err
  end
  def self.main(av)
    if av.size < 2
      puts 'Использование ruby scripts/validate.rb <решения.json> <очередь.json> [провайдеры.json]'
      exit 1
    end
    dec = read(av[0])
    que = read(av[1])
    raw = read(av[2] || File.join(BASE, 'data', 'providers.json'))
    prs = raw.is_a?(Array) ? raw : raw['providers']
    que = que['operations'] if que.is_a?(Hash)
    dec = [dec] unless dec.is_a?(Array)
    ok = 0
    bad = 0
    puts "заявок в очереди #{que.size}, решений #{dec.size}"
    puts
    qid = que.map { |o| o['operation_id'].to_s }
    did = dec.map { |d| d['operation_id'].to_s }
    mis = qid - did
    ext = did - qid
    dup = did.tally.select { |_, c| c > 1 }.keys
    if mis.any?
      puts "нет решений для #{mis.size} заявок #{mis.first(5).join(', ')}"
      bad += mis.size
    else
      puts 'все заявки очереди покрыты'
      ok += 1
    end
    if ext.any?
      puts "лишние operation_id #{ext.size} #{ext.first(5).join(', ')}"
      bad += ext.size
    end
    if dup.any?
      puts "дубли #{dup.first(5).join(', ')}"
      bad += dup.size
    end
    err = form(dec)
    if err.any?
      puts "ошибок структуры #{err.size}"
      err.first(10).each { |e| puts "   #{e}" }
      bad += err.size
    else
      puts 'структура JSON корректна'
      ok += 1
    end
    puts
    det = 0
    que = que.map {|o| o.is_a?(Hash) ? o : {} }
    que.each do |o|
      d = dec.find { |x| x['operation_id'].to_s == o['operation_id'].to_s }
      next unless d
      elg = orig(o['amount'], o['bank'].to_s, prs)
      sel = d['selected_provider']
      if elg.include?(sel)
        ok += 1
      else
        puts "#{o['operation_id']} выбран #{sel} НЕ допустим, допустимы #{elg.join(', ')}"
        bad += 1
      end
      out = elg.reject { |n| n == SELF }
      next unless out.size == 1
      det += 1
      next if sel == out.first
      puts "#{o['operation_id']} детерминированный кейс, ожидался #{out.first}, выбран #{sel}"
      bad += 1
    end
    puts "допустимость выбранного проверена на #{que.size} заявках"
    puts "детерминированных кейсов найдено #{det}, все совпали" if det.positive?
    puts
    amt = que.to_h { |o| [o['operation_id'].to_s, Float(o['amount'], exception: false)||0.0] }
    use = Hash.new(0.0)
    dec.each { |d| use[d['selected_provider']] += amt[d['operation_id'].to_s].to_f if d['simulated_result'] == 'approved' }
    prs.each do |p|
      lim = p['daily_amount_limit']
      next if lim.nil?
      tot = p['daily_approved_amount'].to_f + use[p['payment_system']]
      next if tot <= lim
      puts "#{p['payment_system']} дневной лимит превышен #{tot.round} > #{lim}"
      bad += 1
    end
    puts 'дневные лимиты не превышены'
    puts
    puts "распределение #{dec.map { |d| d['selected_provider'] }.tally.sort.map { |k, v| "#{k}=#{v}" }.join('  ')}"
    puts "исходы #{dec.map { |d| d['simulated_result'] }.tally.map { |k, v| "#{k}=#{v}" }.join('  ')}"
    puts
    puts 'Итого'
    puts "пройдено #{ok}"
    puts "ошибок #{bad}"
    exit(bad.zero? ? 0 : 1)
  end
end
Val.main(ARGV)
