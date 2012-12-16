#!/usr/bin/env node
inteval = 5

config = require 'yaml-config'
request = require 'request'
fs = require('fs');

Iconv = require('iconv').Iconv
gbk_to_utf8 = new Iconv 'GBK', 'UTF-8'

settings = config.readConfig process.cwd() + '/' + "config.yaml"
console.log settings
request settings.servers, (error, response, body)->
  servers = JSON.parse body
  main servers
  setInterval ->
    main servers
  , inteval * 1000

main = (servers)->
  for server in servers
    try
      request {url: server.index + '/?operation=getroomjson', encoding: 'binary'}, (error, response, body)->
        refresh(server, JSON.parse gbk_to_utf8.convert(new Buffer(body,'binary')).toString())
    catch e
      if server.error_count?
        server.error_count++
      else
        server.error_count = 1
      console.log e

refresh = (server, data)->
  parse_room server, room for room in data.rooms


parse_room = (server, data)->
  id = String.fromCharCode('A'.charCodeAt() + server.id) + data.roomid
  matched = data.roomname.match /^(P)?(M)?(T)?\#?(.*)$/
  result = {id: id, name: matched[4], status: data.istart, pvp: matched[1]?, match: matched[2]?, tag: matched[3]?, lp: 8000, private: data.needpass == "true"}
  console.log result
parse_user = (server, data)->
  {id: data.name, name: data.name, nickname: data.name, certified: data.id == "-1"}