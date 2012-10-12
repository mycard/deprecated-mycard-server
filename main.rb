#!/usr/bin/env ruby
Config = 'config.yml'
Log = STDOUT
Interval = 2

require 'eventmachine'
require 'em-http-request'
require 'json'
require 'logger'
require 'xmpp4r'
require 'xmpp4r/muc'
require 'yaml'
require 'daemons'
require 'rexml/element'


def load_servers
  http = EventMachine::HttpRequest.new($config['api']).get
  http.callback {
    $config['servers'] = JSON.parse http.response
    $config['servers'].each {|server|
      server['error_count'] = 0
      server['rooms'] = []
    }
    open(Config, 'w') { |conf| YAML.dump $config, conf }
  }
  http.errback {
    $log.warn('load servers') { http.error }
  }
end

def update(server, reply)
  reply.force_encoding("GBK").encode!("UTF-8", :invalid => :replace, :undef => :replace)
  begin
    reply = JSON.parse reply
    server['error_count'] = 0
  rescue
    server['error_count'] += 1
    $log.warn("server_error_#{server[:name]}_#{server[:error]}") { reply }
    if server['error_count'] >= 5
      reply = {"rooms" => []}
    else
      return
    end
  end


  rooms = reply["rooms"].collect { |room| parse_room(room) }
  rooms_changed = rooms - server['rooms'] + server['rooms'].select { |room| (server['rooms'].collect { |room| room['id'] } - rooms.collect { |room| room['id'] }).include? room['id'] }.collect { |room| room['_deleted'] = true; room }
  return if rooms_changed.empty?
  server['rooms'].replace rooms

  server = server.dup
  server.delete 'rooms'
  result = REXML::Element.new('server')
  result.add_attributes server
  rooms_changed.each { |room|
    room = room.dup
    users = room.delete 'users'
    room_element = result.add_element('room')
    room_element.add_attributes room
    users.each { |user|
      user_element = room_element.add_element('user')
      user_element.add_attributes user
    }
  }

  $xmpp_conference.send(Jabber::Message.new(nil, '喵'))

  #puts result
end

def self.parse_room(room)
  #struct HostInfo {
  #  unsigned int lflist;
  #  unsigned char rule;
  #  unsigned char mode;
  #  bool enable_priority;
  #  bool no_check_deck;
  #  bool no_shuffle_deck;
  #  unsigned int start_lp;
  #  unsigned char start_hand;
  #  unsigned char draw_count;
  #  unsigned short time_limit;
  #};
  decode(room["roomname"]) =~ /^(P)?(M)?(T)?\#?(.*)$/

  room = {
      'id' => room["roomid"].to_i,
      'name' => $4,
      'status' => room["istart"].to_sym,
      'pvp' => !!$1,
      'private' => room["needpass"] == "true",

      'lflist' => 0,
      'rule' => 0,
      'mode' => $2 ? $3 ? 2 : 1 : 0,
      'enable_priority' => false,
      'no_check_deck' => false,
      'no_shuffle_deck' => false,
      'start_lp' => 8000,
      'start_hand' => 5,
      'draw_count' => 1,
      'time_limit' => 0,

      'users' => room["users"].collect{|user|parse_user(user)}
  }

  if room['name'] =~ /^(\d)(\d)(F)(F)(F)(\d+),(\d+),(\d+),(.*)$/
    room['rule'] = $1.to_i
    room['mode'] = $2.to_i
    room['start_lp'] = $6.to_i
    room['start_hand'] = $7.to_i
    room['draw_count'] = $8.to_i
    room['name'] = $9
  end

  room
end

def parse_user(user)
  {'name' => decode(user['name']), 'certified' => user["id"]=="-1", 'pos' => user['pos'] % 2}
end

def decode(str)
  [str].pack('H*').force_encoding("UTF-16BE").encode("UTF-8", :undef => :replace, :invalid => :replace)
end


Dir.chdir(File.dirname(__FILE__))
$config = YAML.load_file Config
$log = Logger.new Log
puts YAML.dump $config

$config['servers'].each {|server|
  server['error_count'] = 0
  server['rooms'] = []
}

$xmpp = Jabber::Client::new Jabber::JID.new $config['xmpp']['jid']
port = $config['xmpp']['port'] || 5222
if RUBY_PLATFORM['mingw'] || RUBY_PLATFORM['mswin']
  $xmpp.use_ssl = true
  $xmpp.allow_tls = false
  port = $config['xmpp']['ssl_port'] || 5223
end
$xmpp.connect($config['xmpp']['host'] || $xmpp.jid.domain, port)
$xmpp.auth($config['xmpp']['password'])

$xmpp_conference = Jabber::MUC::MUCClient.new $xmpp
$xmpp_conference.join $config['xmpp']['conference']

begin
  EventMachine::run {
    load_servers
    EM.add_periodic_timer(Interval) {
      $config['servers'].each_with_index { |server|
        http = EM::HttpRequest.new(server['index'] + '?operation=getroomjsondelphi').get
        http.callback { update(server, http.response) }
        http.errback { server['error_count'] += 1 }
      }
    }
  }
rescue
  $log.fatal 'error: ' + $!.inspect + $!.backtrace.inspect
  retry
end
