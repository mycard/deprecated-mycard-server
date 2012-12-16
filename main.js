var http = require('http'),
    buffer = require('buffer'),
    iconv = require('iconv').Iconv,
    url = require('url').parse('http://master.smdcn.net:7922/?operation=getroomjson');
var request = require('request');

request({url: url, encoding: 'binary'}, function(error, response, body){
    console.log((new iconv('GBK','UTF-8')).convert(new Buffer(body,'binary')).toString());
})
/*
http.get(url,function(res){
    var html = '';
    res.setEncoding('binary');//or hex
    res.on('data', function (chunk) {
        html += chunk;
    });
    res.on('end',function(){
        console.log((new iconv('GBK','UTF-8')).convert(new Buffer(html,'binary')).toString());
    });
})
*/