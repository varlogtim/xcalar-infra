var http = require('http'),
    https = require('https'),
    httpProxy = require('http-proxy')
var AWS = require('aws-sdk');

var ec2 = new AWS.EC2({region: "us-west-2"});
var proxy = httpProxy.createServer();

var server = http.createServer(async function (req, res) {
    // XXX Not working because of SSL
    // if (req.url.startsWith("/auth")) {
    //     // auth forwarding
    //     console.log("auth forwarding");
    //     res.writeHead(500, { 'Content-Type': 'application/json' });
    //     res.end({error: "not supported"});
    // } else if (req.url.startsWith("/cluster") ||
    //            req.url.startsWith("/billing") ||
    //            req.url.startsWith("/s3")) {
    //     // other lambda forwrading
    //     console.log("saas api forwarding");
    //     proxy.web(req, res, {
    //         target: {
    //             protocol: "https",
    //             host: "g6sgwgkm1j.execute-api.us-west-2.amazonaws.com",
    //             port: 443
    //         },
    //         changeOrigin: true,
    //         autoRewrite: true,
    //         xfwd: true,
    //         hostRewrite: true,
    //         protocolRewrite: true
    //     });
    // } else {
    // xcalar cluster forwarding
    var params = {
        Filters: [
            {
                "Name": "tag:Owner",
                "Values": [req.headers.username]
            }
        ]
    };
    var data;
    try {
        data = await ec2.describeInstances(params).promise();
    } catch(e) {
        console.log(e, e.stack);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end({error: err});
        return;
    }
    var reservations = data.Reservations;
    var allInstances = [];
    for (var reservation of data.Reservations) {
        for (var instance of reservation.Instances) {
            if (instance.State.Name === "running") {
                allInstances.push({
                    index: instance.AmiLaunchIndex,
                    timestamp: instance.LaunchTime,
                    ip: instance.PrivateIpAddress
                });
            }
        }
    }
    if (allInstances.length < 1) {
        // no instance
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end({error: "No running cluster"});
        return;
    }
    allInstances.sort(function(i1, i2) {
        if (i1.timestamp === i2.timestamp) {
            return i1.index - i2.index;
        } else {
            return i1.timestamp - i2.timestamp;
        }
    });
    var ip = allInstances[0].ip;
    var target = 'https://' + ip;
    proxy.web(req, res, {target: target, secure: false});
}).listen(9000);

// server.on('connect', function (req, socket) {
//     var ip;
//     if (routingMap.hasOwnProperty(req.headers.username)) {
//         ip = routingMap[req.headers.username];
//     } else {
//         var params = {
//             Key: {
//                 "username": {
//                     S: req.headers.username
//                 }
//             }, 
//             TableName: "saas_routing"
//         };
//         try {
//             let resp = await dynamodb.getItem(params);
//             ip = resp.Item.Address.S;
//         } catch (e) {
//             console.error("failed: ", e);
//         }
//     }
//     var target = 'http://' + ip + '6578';
//     proxy.ws(req, socket, {target: target, secure: false});
// });

