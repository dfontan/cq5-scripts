#!/usr/bin/env ruby

require 'optparse'
require 'ostruct'
require 'pp'

require 'highline/import' #optional?
require 'net/http'
require 'uri'
require 'json'

class CQPasswordOpts
  def self.parse(args)
    options = OpenStruct.new

    # defaults
    options.verbose = false
    options.user   = 'admin'
    options.oldpwd = nil
    options.newpwd = nil
    options.hostnames = []
    options.port = '4502'
    options.cq5_version = '5.4'

    opts = OptionParser.new do |opts|
      opts.banner = "Usage: #{File.basename($0)} [options]\n"
      opts.separator "\nSpecific options:"

      opts.on("-cv", "--cqversion CQ5_VERSION", %w{ 5.4, 5.5 },
              "CQ5 Version (default: 5.4, 5.5)") { |ver| options.cq5_version = ver }

      opts.on("-u", "--user OLD_PASSWORD",
              "username to change (default: admin)") { |user| options.user = user }

      opts.on("-o", "--oldpwd OLD_PASSWORD",
              "Old CQ5 admin password") { |pwd| options.oldpwd = pwd }

      opts.on("-n", "--newpwd NEW_PASSWORD",
              "New CQ5 admin password") { |pwd| options.newpwd = pwd }

      opts.on("-P", "--port N", "Port number (Default: 4502)") { |n| options.port = n }

      opts.on("-s", "--server HOSTNAME:[PORT]", "Host to change passwords on, with optional port",
        "(you can provide this multiple times, e.g. -s foo.lan:4509 -s bar.net)") do |host|
          options.hostnames << ( ( host.split(':').length > 1 ) ? host.split(':') : [ host, options.port ] )
      end

      opts.on("-v", "--[no-]verbose", "Run verbosely") { |v| options.verbose = v }

      opts.on_tail("--help", "Show this message") do
        puts opts
        exit
      end

    end

    options.hostnames << [ 'localhost', options.port ] if options.hostnames.empty?

    opts.parse!(args)

    # prompts
    options.oldpwd = ask("Enter old admin password:  ") { |q| q.echo = false } if options.oldpwd.nil?
    options.newpwd = ask("Enter new admin password:  ") { |q| q.echo = false } if options.newpwd.nil?

    options
  end
end

def http_fetch(url, auth_user = 'admin', auth_pass = 'admin')
  uri  = URI.parse(url)

  req  = Net::HTTP::Post.new(uri.request_uri)
  req.basic_auth(auth_user, auth_pass)

  http = Net::HTTP.new(uri.host, uri.port)
  http.request(req).body
end

def http_req(url, auth_user = 'admin', auth_pass = 'admin', datahash = {} ) 
  uri  = URI.parse(url)

  req  = Net::HTTP::Post.new(uri.request_uri)
  req.basic_auth(auth_user, auth_pass)
  req.set_form_data(datahash)

  http = Net::HTTP.new(uri.host, uri.port)
  http.request(req)
end

# step 1
# curl -s --data plain=$NEW_PWD --data verify=$NEW_PWD --user admin:$OLD_PWD http://$HOST:$PORT/crx/ui/setpassword.jsp
#def chpwd_crx(host, port, user, old_pwd, new_pwd)
def chpwd_crx(host, port, opts)
  http_req("http://#{host}:#{port}/crx/ui/setpassword.jsp", opts.user, opts.oldpwd, {"verify" => opts.newpwd, 'plain' => opts.newpwd})
end

def chpwd_slingclientrepo(host, port, opts)
  datahash = { 'apply'          => 'true',
               'admin.password' => opts.newpwd,
               'propertylist'   => 'admin.password', } 
  factory_pid = 'com.day.crx.sling.client.impl.CRXSlingClientRepository'
  jsondoc = http_fetch("http://#{host}:#{port}/system/console/configMgr/(service.factoryPid=#{factory_pid}).json", opts.user, opts.oldpwd)
  pid = JSON.parser.new(jsondoc).parse.first['pid']
  http_req("http://#{host}:#{port}/system/console/configMgr/#{pid}", opts.user, opts.oldpwd, datahash)

  # curl -s -u admin:$CONSOLE_PWD -dapply=true -dadmin.password=$NEW_PWD -dpropertylist=admin.password
  # http://$HOST:$PORT/system/console/configMgr/$PID
end

def chpwd_felixwebconsole(host, port, opts)
  datahash = { 'apply'          => 'true',
               'admin.password' => opts.newpwd,
               'propertylist'   => 'admin.password', } 
  osgi_pid = 'org.apache.felix.webconsole.internal.servlet.OsgiManager'
  http_req("http://#{host}:#{port}/system/console/configMgr/#{pid}", opts.user, opts.oldpwd, datahash)
end

def chpwd_cqse(host, port, opts)

  # generally step 3
  datahash = { :username       => opts.user,
               :password_old   => opts.oldpwd,
               :password       => opts.newpwd,
               :password_check => opts.newpwd, }
  http_req("http://#{host}:#{port}/admin/passwd", datahash, opts.user, opts.oldpwd)

  # curl -s --data username="admin" --data password_old=\'$OLD_PWD\' --data password=\'$NEW_PWD\' --data password_check=\'$NEW_PWD\'
  # --user admin:\'$OLD_PWD\' http://$HOST:$PORT/admin/passwd
end

# synopsis (from
# http://dev.day.com/docs/en/cq/5-4/deploying/security_checklist.html):
# 1. change CRX password @ /crx
# 2. change felix osgi console password @ /system/console/configMgr
# 3. change cqse (Day Servlet Engine) password @ /admin/passwd
def change54( host, port, options )
  pp chpwd_crx( host, port, options )
  pp chpwd_slingclientrepo( host, port, options )
  pp chpwd_cqse( host, port, options )
  pp chpwd_felixwebconsole( host, port, options )
end

options = CQPasswordOpts.parse(ARGV)

if options.cq5_version.strip =~ /5.5/
  puts "ERROR: CQ5.5 not implemented yet!!"
  exit
end

pp options

options.hostnames.each do |host|
  begin
    change54( host.first, host.last, options)
  rescue Errno::ECONNREFUSED
    puts "ERROR: Couldn't connect to #{host.first}:#{host.last}."
  end
end

