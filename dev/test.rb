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
require 'digest/sha1'

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
    verbose = true
    Typhoeus::Config.verbose = true
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

def get(url, opt = {})
  url = "#{$server_url}#{url}" if url[0]=="/"
  Typhoeus.get(url, followlocation: true)
end
def get_until(url, fin, opt = {})
  max_wait = opt[:max_wait] || 10
  neg = false
  if fin[0]=="!"
    fin = fin[1..fin.length]
    neg = true
  end
  fin = fin.to_sym
  start = Time.now
  while true do
    resp = get(url, opt)
    puts resp.return_code
    if neg then
      break if resp.return_code != fin
    else
      break if resp.return_code == fin
    end
    if Time.now - t > max_wait
      raise "failed to get #{url} after #{max_wait} sec."
    end
    sleep opt["retry_time"] || 0.2
  end
  return resp
end

class Nginx
  def self.start(opt = "")
    @@pid = Process.spawn("./nginx.sh #{opt}")
    get_until "http://127.0.0.1:8082/ready", :ok
    return pid
  end  
  def self.pid
    @@pid
  end
  def self.stop
    Process.kill "TERM", @@pid
    print "stop nginx"
    get_until "http://127.0.0.1:8082/ready", :couldnt_connect
  end
end

Nginx.start "1"
Minitest.after_run do
  Nginx.stop
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
    DEFAULT_WEIGHT = 100
    def hit(srv_name)
      @hits[srv_name] = (@hits[srv_name] || 0) + 1
    end
    attr_accessor :hits, :weights, :name
    
    def balanced?(max_error=0.05)
      total_weight = @weights.values.sum.to_f || 0
      total_hits = @hits.values.sum.to_f || 0
      errors = {}
      @servers.each do |name, srv|
        expected = total_hits * (@weights[name] || 0) / total_weight
        errors[name]=((@hits[name] || 0) - expected)/expected
      end
      if errors.values.max.abs > max_error
        msg = errors.map {|k, v| "#{k}:#{v>0 ? '+':'-'}#{v.abs*100}%"}.join ", "
        return false, msg
      end
      return true
    end
    
    def initialize(name, servers={})
      @name = name
      @hits = {}
      @weights = {}
      @servers = {}
      servers.each do |server_config|
        server = start_server(server_config) do |env, this_server|
          path = env["REQUEST_PATH"] || env["PATH_INFO"]
          puts "hit path #{path}"
          if path != "/ready"
            self.hit this_server.name
          end
        end
        @servers[server.name] = server
        weight = Hash === server_config ? server_config[:weight] : DEFAULT_WEIGHT
        @weights[server.name] = weight || DEFAULT_WEIGHT
      end
    end
    
    def stop
      name, srv = @servers.first
      srv.stop if srv #thanks to a celluloid quirk, this stops all supervised servers
      @servers.each do |name, v|
        get_until "http://#{name}/ready", :couldnt_connect
      end
      @servers = {}
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
    
  def upstream(name, opt)
    up = Upstream.new name, opt
    @upstreams << up
    up
  end
  
  def assert_balanced(upstream, max_error=0.05)
    ok, err = upstream.balanced?(max_error)
    err = "upstream #{upstream.name} not balanced: #{err}" if not ok
    assert ok, err
  end
  
  def test_simple_roundrobin
    up =  upstream "simple_roundrobin", [8083, 8084]
    10.times { get "/simple_roundrobin"}
    assert_balanced up
  end
end
