module Routing
  class Constraints
    RULES= ['stat',  'traf','amin','amax','dyly','ipct','ipam','reqs','marg','bnks','rate'].freeze
    WINDOW=60
    def initialize(cfg = {})
      @win =(cfg['window_sec']||WINDOW).to_f
    end
    def deny(prv, op, now = nil)
      RULES.each do |r|
        res = send(r, prv, op, now)
        return res if res
      end
      nil
    end
    def pass(prs, op, now = nil)
      prs.reject {|p| deny(p, op, now) }
    end
    def scan(prs, op, now = nil)
      prs.to_h {|p| [p.name, deny(p, op, now)] }
    end
    private
    def rej(cod, txt)
      { 'reason' => cod, 'details' => txt }
    end
    def fmt(val)
      return 'не задан' if val.nil?
      num= val.to_f
      num==num.to_i ? num.to_i.to_s : format('%.2f', num)
    end


    def stat(prv, _op, _now)
      return nil if prv['status']=='active'
      rej('provider_inactive', "провайдер не актив #{prv['status'].inspect} (status)")
    end
    def traf(prv, _op, _now)
      return nil unless prv.num('traffic_percentage').to_f.zero?
      return nil if prv.own?
      rej('traffic_disabled', 'трафик отключ доля 0')
    end
    def amin(prv, op, _now)
      lim= prv.num('limit_amount_min')
      return nil if lim.nil?||op.amt>=lim
      rej('amount_below_minimum', "сумма ниже min #{fmt(op.amt)} < #{fmt(lim)}")
    end
    def amax(prv, op, _now)
      lim= prv.num('limit_amount_max')
      return nil if lim.nil?||op.amt<=lim
      rej('amount_exceeds_limit', "сумма выше max #{fmt(op.amt)} > #{fmt(lim)}")
    end
    def dyly(prv, op, _now)
      lim = prv.num('daily_amount_limit')
      return nil if lim.nil?
      cur = prv.num('daily_approved_amount').to_f+prv.num('daily_reserved').to_f+op.amt
      return nil if cur<=lim
      rej('daily_limit_exceeded', "дневной оборот все #{fmt(cur)} > #{fmt(lim)}")
    end
    def ipct(prv, _op, _now)
      lim = prv.num('in_progress_count_limit')
      return nil if lim.nil?
      cur = prv['in_progress_count']+1
      return nil if cur<=lim
      rej('in_progress_count_exceeded', "слишком много заявок #{fmt(cur)} > #{fmt(lim)}")
    end




    def ipam(prv, op, _now)
      lim = prv.num('in_progress_amount_limit')
      return nil if lim.nil?
      cur = prv.num('in_progress_amount').to_f+op.amt
      return nil if cur<=lim
      rej('in_progress_amount_exceeded', "сумма в работе превышена #{fmt(cur)} > #{fmt(lim)}")
    end
    def reqs(prv, _op, _now)
      return nil if prv['available_requisites']>0
      rej('no_available_requisites', "нет свободных реквизитов #{prv['available_requisites']}")
    end
    def marg(prv, _op, _now)
      own = prv.num('provider_margin_pct').to_f
      mer = prv.num('merchant_margin_pct').to_f
      return nil if own<=mer||prv['allow_negative_agreement']
      rej('negative_margin', "маржа провайдера выше мерчанта #{fmt(own)} > #{fmt(mer)}")
    end
    def bnks(prv, op, _now)
      lst = prv['banks']||[]
      return nil if lst.empty?
      has = lst.include?(op.bank)
      return rej('bank_excluded', "банк в исключ #{op.bank} из #{lst.join(', ')}") if prv['exclude_banks']&&has
      return nil if prv['exclude_banks']||has
      rej('bank_not_in_list', "банк не обслуживается #{op.bank}, разрешены #{lst.join(', ')} ")
    end
    def rate(prv, _op, now)
      lim =prv['requests_minut']||prv['requests_per_minute_limit']
      return nil if lim.nil?||now.nil?
      cnt= prv['dispatch_times'].count {|t| now-t<@win }+1
      return nil if cnt<=lim.to_i
      rej('rate_limi', "превышена интенсивност #{cnt} > #{lim} заявок за #{@win.to_i}")
    end
  end
end
