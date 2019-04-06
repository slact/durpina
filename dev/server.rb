#!/bin/ruby
require 'rubygems'
require 'bundler/setup'
require "pry"
require 'celluloid/current'
require 'celluloid/logger'
require "rack"
require "reel/rack/cli"
require 'reel/rack'
require "optparse"

module ReelConnectionExtensions
  def respond(code, headers, body=nil)
    if code == :ignore
      @current_request = nil
      @parser.reset
    else
      super
    end
  end
end
class Reel::Connection
  prepend ReelConnectionExtensions
end

module ReelServeExtensions
  def status_symbol(status)
    if status == -1
      :ignore
    else
      super
    end
  end
end
class Reel::Rack::Server
  prepend ReelServeExtensions
end

class Server
  attr_accessor :app
  
  def print_request(env, body=nil)
    if @opt[:verbose]
      out = []
      out << "  #{env["REQUEST_METHOD"]} #{env["PATH_INFO"]}#{env['QUERY_STRING']!="" ? "?#{env['QUERY_STRING']}" : ""}"
      if @opt[:very_verbose]
        out << "  Host: #{env["HTTP_HOST"]}"
        env.each do |k,v|
          if k != "  HTTP_HOST" && k =~ /^HTTP_/
            out << "  #{k.split("_").slice(1..-1).each(&:capitalize!).join('-')}: #{v}"
          end
        end
      end
      out << "  #{body}"
      puts out.join("\n")
    end
  end
  
  def initialize(opt={})
    @opt = opt || {}
    @opt[:Port] = @opt[:port] || 8053
    @opt[:Host] = @opt[:host] || "127.0.0.1"
    
    if block_given?
      opt[:callback]=Proc.new
    end
    
    @app = proc do |env|
      resp = []
      headers = {}
      code = 200
      body = env["rack.input"].read
      chunked = false
      
      print_request env, body
      
      case env["REQUEST_PATH"] || env["PATH_INFO"]
      when "/ready"
        resp << "ready"
      else
        code = 200
        resp << (env["REQUEST_PATH"] || env["PATH_INFO"])
      end
      
      if @opt[:callback]
        @opt[:callback].call(env, self)
      end
      
      headers["Content-Length"]=resp.join("").length.to_s unless chunked
      
      [ code, headers, resp ]
    end
    
    @opt = Rack::Handler::Reel::DEFAULT_OPTIONS.merge(@opt)
    @app = Rack::CommonLogger.new(@app, STDOUT) unless @opt[:quiet]
  end
  
  def name
    "#{@opt[:Host]}:#{@opt[:Port]}"
  end
  
  def run
    ENV['RACK_ENV'] = @opt[:environment].to_s if @opt[:environment]
    
    
    @supervisor = Reel::Rack::Server.supervise(as: :"reel_rack_server-#{self.name}", args: [@app, @opt])
    
    if __FILE__ == $PROGRAM_NAME
      begin
        sleep
      rescue Interrupt
        Celluloid.logger.info "Interrupt received... shutting down" unless @opt[:quiet] 
        @supervisor.terminate
      end
    end
  end
  
  def stop
    @supervisor.terminate if @supervisor
  end

  def publisher_upstream_transform_message(msg)
    "WEE! + #{msg}"
  end
end



if __FILE__ == $PROGRAM_NAME then
  opt = {}
  opt_parser=OptionParser.new do |opts|
    opts.on("-q", "--quiet", "Be quiet!"){ opt[:quiet] = true}
    opts.on("--very-verbose", "Be very loud."){ opt[:very_verbose] = true; opt[:verbose] = true}
    opts.on("-v", "--verbose", "Be loud."){ opt[:verbose] = true}
  end
  opt_parser.parse!
  
  srv = Server.new opt
  srv.run
end
