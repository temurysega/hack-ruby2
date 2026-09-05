require 'json'
ROOTDIR = File.expand_path('..', __dir__)
DATADIR = File.join(ROOTDIR,'data')
['models/provider','models/operation','constraints','history','scoring','config','simulator','router','reporter'].each do |f|
  require File.join(ROOTDIR,'lib', 'routing', f)
end
module Fix
  def self.json(nam)
    JSON.parse(File.read(File.join(DATADIR, nam)))
  end
  def self.prov
    Routing::Models::Provider.list(json('providers.json')['providers'])
  end
  def self.queue
    Routing::Models::Operation.list(json('operations_queue_10.json'))
  end
  def self.hist
    Routing::History.load(File.join(DATADIR, 'operations_history.csv'))
  end
  def self.oper(amt, bnk, oid = 'x')
    Routing::Models::Operation.new({'operation_id'=>oid,'amount'=>amt,'bank'=>bnk})
  end
end
RSpec.configure do |c|
  c.disable_monkey_patching!
  c.order = :defined
end
