require 'yaml'
require_relative 'scoring'
module Routing
  class Config
    DEFPATH=File.expand_path('../../config/strategy.yml',__dir__)
    def self.load(pth = DEFPATH, nam = nil)
      raise ArgumentError,"конфиг не найден: #{pth}" unless File.file?(pth.to_s)
      raw= YAML.safe_load_file(pth, aliases: true)
      raise ArgumentError,'конфиг пустой или не обект' unless raw.is_a?(Hash)
      new(raw, nam)
    end
    def initialize(raw, nam = nil)
      raise ArgumentError,'ожидался объект' unless raw.is_a?(Hash)
      pfs =raw['profiles']
      raise ArgumentError,'в конфиге нет секции профилией' unless pfs.is_a?(Hash)&&pfs.any?
      @raw = raw
      @nam = (nam||raw['active_profile']||pfs.keys.first).to_s
      raise ArgumentError,"профиль #{@nam.inspect} не найден, доступны: #{pfs.keys.join(', ')}" unless pfs.key?(@nam)
      @pro = (pfs[@nam]||{})['weights']
      raise ArgumentError,"у профиля #{@nam} нет весов" unless @pro.is_a?(Hash)&&@pro.any?
      bad= @pro.keys-Scoring::SIGNALS
      raise ArgumentError,"профиль имет #{@nam} неизвестные сигналы #{bad.join(', ')}" if bad.any?
    end



    def sco
      {'weights'=>@pro,'declared_weight'=>@raw['declared_weight'],'bands'=>@raw['bands']||[],'turnover'=>@raw['turnover']||{} }
    end
    def sim
      @raw['simulation']||{}
    end
    def win
      { 'window_sec'=>(@raw['rate_limit']||{})['window_sec'] }
    end
    def prof
      @nam
    end
    def list
      @raw['profiles'].keys
    end
  end
end
