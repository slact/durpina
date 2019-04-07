#!/usr/bin/env ruby
require 'rubygems'
require 'bundler/setup'

require 'minitest'
require 'minitest/reporters'
require "minitest/autorun"
Minitest::Reporters.use! [Minitest::Reporters::SpecReporter.new(:color => true)]
require 'securerandom'
require_relative 'server.rb'
require "optparse"
require "json"
require "typhoeus"

$server_url="http://127.0.0.1:8082"
$omit_longmsg=false
$verbose=false
$ordered_tests = false

extra_opts = []
orig_args = ARGV.dup

opt=OptionParser.new do |opts|
  opts.on("--server SERVER (#{$server_url})", "server url."){|v| $server_url=v}
  opts.on("--default-subscriber TRANSPORT (#{$default_client})", "default subscriber type"){|v| $default_client=v.to_sym}
  opts.on("--verbose", "set Accept header") do |v| 
    $verbose = true
    #Typhoeus::Config.verbose = true
  end
  opts.on("--omit-longmsg", "skip long-message tests"){$omit_longmsg = true}
  opts.on_tail('-h', '--help', 'Show this message!!!!') do
    puts opts
    raise OptionParser::InvalidOption , "--help"
  end
  opts.on("--ordered", "order tests alphabetically"){$ordered_tests = true}
end

begin
  opt.parse!(ARGV)
rescue OptionParser::InvalidOption => e
  extra_opts << e.args
  retry
end

(orig_args & ( ARGV | extra_opts.flatten )).each { |arg| ARGV << arg }

def url(part="")
  part=part[1..-1] if part[0]=="/"
  "#{$server_url}/#{part}"
end

def post(url, data)
  url = "#{$server_url}#{url}" if url[0]=="/"
  resp = Typhoeus.post(url, headers: {'Content-Type'=> "text/json"}, body: data.to_json)
  if resp.return_code == :ok then
    return true
  else
    return nil, "POST to #{url} failed"
  end
end

def get(url, opt = {})
  url = "#{$server_url}#{url}" if url[0]=="/"
  Typhoeus.get(url, followlocation: true)
end
def get_until(url, fin, opt = {})
  max_wait = opt[:max_wait] || 3
  neg = false
  if fin[0]=="!"
    fin = fin[1..fin.length]
    neg = true
  end
  fin = fin.to_sym
  start = Time.now
  while true do
    resp = get(url, opt)
    if neg then
      break if resp.return_code != fin
    else
      break if resp.return_code == fin
    end
    if Time.now - start > max_wait
      raise "failed to get #{url} after #{max_wait} sec."
    end
    sleep opt[:retry_time] || 0.2
  end
  return resp
end
def get_repeat(url, reps=100, opt={})
  codes = {}
  reps.times do
    resp = get url, opt
    codes[resp.return_code]=(codes[resp.return_code] || 0) + 1
  end
  return codes
end

class Nginx
  attr_accessor :pid, :worker_pids
  def start(opt = "")
    Process.spawn("./nginx.sh #{opt}")
    get_until "http://127.0.0.1:8082/ready", :ok
    pid
  end  
  def pid
    begin
      pid = File.read ".pid"
    rescue
      return nil
    end
    pid ? pid.to_i : nil
  end
  def stop
    master_pid = pid
    Process.kill "TERM", master_pid if master_pid
    get_until "http://127.0.0.1:8082/ready", :couldnt_connect
  end
end

nginx = Nginx.new

nginx.stop
nginx.start "10 #{$verbose ? 'loglevel=notice' : 'loglevel=warn'}"
Minitest.after_run do
  nginx.stop
end

class UpstreamTest <  Minitest::Test  
  if $ordered_tests
    def self.test_order
      :alpha
    end
  end
  def setup
    Celluloid.boot
    @upstreams = []
  end
  def teardown
    @upstreams.each { |up| up.stop }
  end
  class Upstream
    DEFAULT_WEIGHT = 1
    def hit(srv_name)
      @hits[srv_name] = (@hits[srv_name] || 0) + 1
    end
    attr_accessor :hits, :weights, :name, :responses
    
    def response_counts_match?
      return true if not @responses
      total_hits = @hits.values.sum.to_f || 0
      return true if total_hits == @responses[:ok]
      return nil, "expected to see #{@responses[:ok]} total ok responses, saw #{total_hits}"
    end
    
    def balanced?(max_error=0.05)
      total_weight = @weights.values.sum.to_f || 0
      total_hits = @hits.values.sum.to_f || 0
      errors = {}
      @servers.each do |name, srv|
        if total_hits == 0
          errors[name]=0
        else
          expected = total_hits * (@weights[name] || 0) / total_weight
          errors[name]=((@hits[name] || 0) - expected)/expected
        end
      end
      if errors.values.max.abs > max_error
        msg = errors.map {|k, v| "#{k}:#{v>0 ? '+':'-'}#{(v.abs*100).round}%"}.join ", "
        return false, msg
      end
      return true
    end
    
    def initialize(name, servers=[], weights=nil)
      @name = name
      @hits = {}
      @weights = {}
      @servers = {}
      servers.each_with_index do |server_config, i|
        server = start_server(server_config) do |env, this_server|
          path = env["REQUEST_PATH"] || env["PATH_INFO"]
          if path != "/ready"
            self.hit this_server.name
          end
        end
        @servers[server.name] = server
        @weights[server.name] = ((Hash === server_config) && server_config[:weight]) || (weights && weights[i]) || DEFAULT_WEIGHT
      end
    end
    
    def stop
      @servers.each do |name, srv|
        srv.stop
        get_until "http://#{name}/ready", :couldnt_connect
      end
      @servers = {}
    end
    
    def server(name)
      if Numeric === name
        srv_name, srv = @servers.find {|k, v| v.port == name}
        return srv
      end
      return srv[name]
    end
    
    def request(url=nil, repeat=1000, opt={})
      if Numeric === url
        repeat = url
        url=nil
      end
      url ||= "/#{@name}"
      @responses ||= {}
      resps = get_repeat(url, repeat, opt)
      resps.each do |k,v|
        @responses[k] = (@responses[k] || 0) + v
      end
      resps
    end
    
    private
    def start_server(opt={}, &block)
      if Numeric === opt
        opt = {port: opt}
      end
      opt[:host] ||= "127.0.0.1"
      opt[:quiet] = true if opt[:quiet].nil? 
      srv = Server.new opt, &block
      srv.run
      get_until "http://#{opt[:host]}:#{opt[:port]}/ready", "!couldnt_connect"
      return srv
    end
  end
    
  def upstream(name, servers, weights=nil)
    up = Upstream.new name, servers, weights
    @upstreams << up
    up
  end
  
  def assert_balanced(upstream, max_error=0.05)
    assert upstream.response_counts_match?
    ok, err = upstream.balanced?(max_error)
    err = "upstream #{upstream.name} not balanced: #{err}" if not ok
    assert ok, err
  end
  def assert_no_errors(upstream)
    upstream.responses.each do |code, count|
      assert code==:ok, "errors found in requests to upstream #{upstream.name}: #{code} (#{count} times)"
    end
  end
  
  def test_simple_roundrobin
    up =  upstream "simple_roundrobin", [8083, 8084, 8085]
    up.request
    assert_no_errors up
    assert_balanced up
  end
  
  def test_weighted_roundrobin
    up =  upstream "weighted_roundrobin", [8083, 8084, 8085], [1, 10, 30]
    up.request
    assert_no_errors up
    assert_balanced up
  end
  
  def test_reweighted_roundrobin
    up =  upstream "reweighted_roundrobin", [8083, 8084, 8085], [10, 20, 30]
    up.request
    assert_no_errors up
    assert_balanced up
    
    assert(post "/set_peer_weight/reweighted_roundrobin", {
      up.server(8084).name => 6,
      up.server(8085).name => 1,
    })
    up.stop
    
    up =  upstream "reweighted_roundrobin", [8083, 8084, 8085], [10, 6, 1]
    up.request 2000
    assert_balanced up
    assert_no_errors up
  end
  
  def test_peer_failure
    up =  upstream "simple_roundrobin", [8083, 8084, 8085], [1, 10, 30]
    up.request
    assert_no_errors up
    assert_balanced up
    
    up.reset
    up.server(8084).stop
    assert_balanced up
    
  end
  
  
end
