'use strict'
const path = require('path')
const express = require('express')
const expressSession = require('express-session');
const cookieParser = require('cookie-parser');
const signature = require('cookie-signature');
const bodyParser = require('body-parser')
const methodOverride = require('method-override');
const passport = require('passport');
const cors = require('cors')
const compression = require('compression')
const awsServerlessExpressMiddleware = require('aws-serverless-express/middleware')
const app = express()
const router = express.Router()
const request = require("request");
const AWS = require('aws-sdk');
const cookie = require('cookie');
const jwt = require('jsonwebtoken');
const https = require('https');
const DynamoDBStore = require('connect-dynamodb')(expressSession);
var config = require('./config');

var defaultJwtHmac = process.env.JWT_SECRET ?
    process.env.JWT_SECRET : "xcalarSsssh";

// Start QuickStart here

var CognitoStrategy = require('passport-cognito').CognitoStrategy;

//
// create the serialize, deserialize, and the strategy callback
//

passport.serializeUser(function(user, done) {
  done(null, user.id);
});

passport.deserializeUser(function(id, done) {
  findById(id, function (err, user) {
    done(err, user);
  });
});

AWS.config.update({region: config.creds.region});

var ddb = new AWS.DynamoDB({apiVersion: '2012-08-10'});

var readUser = function(id, callback) {
    var params = {
        TableName: config.dynamoDBUserTable,
        Key: {
            'id': {S: id}
        }
    };

    ddb.getItem(params, function(err, data) {
        var result = data;

        if (!err && Object.keys(data).length)  {
            result = {
                'profile': data.Item.profile.S,
                'accessToken': data.Item.accessToken.S,
                'refreshToken': data.Item.refreshToken.S,
                'idToken': data.Item.idToken.S,
                'region': data.Item.region.S,
                'identityPoolId': data.Item.identityPoolId.S,
                'awsLoginString': data.Item.awsLoginString.S,
                'identityId': data.Item.identityId.S
            };
        } else {
            result = null;
        }

        console.log(`result: ${JSON.stringify(result)}`);
        return callback(err, result);
    });
}

var writeUser = function(id, item, callback) {
    var params = {
        TableName: config.dynamoDBUserTable,
        Item: {
            'id': {S: id},
            'profile' : {S: item.profile},
            'accessToken': {S: item.accessToken},
            'refreshToken': {S: item.refreshToken},
            'idToken': {S: item.idToken},
            'region': {S: item.region},
            'identityPoolId': {S: item.identityPoolId},
            'awsLoginString': {S: item.awsLoginString},
            'identityId': {S: item.identityId}
        }
    };

    ddb.putItem(params, function(err, data) {
        return callback(err, data);
    });
}

var deleteUser = function(id, callback) {
    var params = {
        TableName: config.dynamoDBUserTable,
        Key: {
            'id': {S: id}
        },
    };

    ddb.deleteItem(params, function(err, data) {
        return callback(err, data);
    });
}

// array to hold logged in users
var users = [];


var findById = function(id, fn) {
    readUser(id, (err, user) => {

        if (err) {
            return fn(err, null);
        } else if (!err && !user) {
            return fn(null, null);
        }

        return fn(null, user ? JSON.parse(user.profile) : null);
    });
};


var findByIdFull = function(id, fn) {
    readUser(id, (err, user) => {

        if (err) {
            return fn(err, null);
        } else if (!err && !user) {
            return fn(null, null);
        }

        return fn(null, user);
    });
};


passport.use(new CognitoStrategy({
    userPoolId: config.creds.userPoolId,
    clientId: config.creds.clientId,
    keysUrl: config.creds.keysUrl,
    region: config.creds.region,
    identityPoolId: config.creds.identityPoolId,
    loggingLevel: config.creds.loggingLevel,
    passReqToCallback: config.creds.passReqToCallback,
},
function(iss, sub, profile, accessToken, refreshToken, awsConfig,
         idToken, region, identityPoolId, awsLoginString,
         identityId, done) {
    if (!profile.id) {
        return done(new Error("No id found"), null);
    }

    // asynchronous verification, for effect...
    process.nextTick(function () {
        findById(profile.id, function(err, user) {
            console.log(`IDENTITYID: ${identityId}`);

            if (err) {
                return done(err);
            }
            if (!user) {
                var item = {
                    'profile': JSON.stringify(profile),
                    'accessToken': accessToken,
                    'refreshToken': refreshToken,
                    'idToken': idToken,
                    'region': region,
                    'identityPoolId': identityPoolId,
                    'awsLoginString': awsLoginString,
                    'identityId': identityId
                }
                // "Auto-registration"
                writeUser(profile.id, item, (err, user) => {

                    if (err) {
                        return done(err);
                    }

                    return done(null, profile);
                });
            } else {
                return done(null, user);
            }
        });
    });
}));

//
// set up the express-session back end
//

var sessionOpts = {
    store: new DynamoDBStore({
        table: config.dynamoDBSessionStoreTable,
        hashKey: config.dynamoDBSessionStoreHashKey,
        prefix: config.dynamoDBSessionStorePrefix,
        AWSRegion: config.creds.region
        }),
    secret: config.sessionSecret,
    cookie: { maxAge: config.sessionAges[config.defaultSessionAge] }
};
app.use(expressSession(sessionOpts));


app.set('view engine', 'pug')

if (process.env.NODE_ENV === 'test') {
  // NOTE: aws-serverless-express uses this app for its integration tests
  // and only applies compression to the /sam endpoint during testing.
  router.use('/sam', compression())
} else {
  router.use(compression())
}

router.use(cors({ "origin": true, credentials: true }))
router.use(bodyParser.json())
router.use(bodyParser.urlencoded({ extended: true }))
router.use(awsServerlessExpressMiddleware.eventContext())

// NOTE: tests can't find the views directory without this
app.set('views', path.join(__dirname, 'views'))

function ensureAuthenticated(req, res, next) {
    if (req.isAuthenticated()) { return next(); }
    res.status(401).send({ 'message': 'Unauthorized' });
    return next('router');
}

function setSessionCookie(res, name, val, secret, options) {
    var signed = 's:' + signature.sign(val, secret);
    var data = cookie.serialize(name, signed, options);

    var prev = res.getHeader('Set-Cookie') || []
    var header = Array.isArray(prev) ? prev.concat(data) : [prev, data];

    res.setHeader('Set-Cookie', header)
}

function setServerCookie(res, name, val, secret, options) {
    var signed = jwt.sign(val, secret);
    var data = cookie.serialize(name, signed, options);

    var prev = res.getHeader('Set-Cookie') || []
    var header = Array.isArray(prev) ? prev.concat(data) : [prev, data];

    res.setHeader('Set-Cookie', header)
}

router.get('/', (req, res) => {
  res.render('index', {
    apiUrl: req.apiGateway ? `https://${req.apiGateway.event.headers.Host}/${req.apiGateway.event.requestContext.stage}` : 'http://localhost:3000'
  })
})

router.get('/sam', (req, res) => {
    res.sendFile(`${__dirname}/sam-logo.png`)
})

router.post('/login', 
    passport.authenticate('cognito'),
    function(req, res, next) {
        console.log(`req.session: ${JSON.stringify(req.session, null, 4)}`);
        console.log(`req.user: ${JSON.stringify(req.user, null, 4)}`);

        console.log('!!!!!! YES !!!!!!!!!!!!');

        req.session.loggedIn = true;

        req.session.loggedInAdmin = false;
        req.session.loggedInUser = true;

        req.session.username = req.user.email;
        req.session.firstName = req.user.givenName;
        req.session.emailAddress = req.user.email;
        req.session.timeout = config.sessionAges['interactive']/1000;

        findByIdFull(req.user.id, (err, user) => {

            if (err) {
                res.status(500).send({"errMsg": JSON.stringify(result.err)});
                return next();
            }

            req.session.idToken = user.idToken;
            req.session.refreshToken = user.refreshToken;
            req.session.region = user.region;
            req.session.identityPoolId = user.identityPoolId;
            req.session.awsLoginString = user.awsLoginString;
            req.session.identityId = user.identityId;

            var payload = {expiresIn: req.session.timeout, audience: "xcalar", issuer: "XCE", subject: "auth id"};
            var token = jwt.sign(payload, defaultJwtHmac);
            res.cookie("jwt_token", token, { maxAge: 1000*req.session.timeout, httpOnly: true, signed: false });

            req.session.save(function(err) {
                res.status(200).send({"message": "Authentication successful",
                                      "sessionId": Buffer.from(req.sessionID).toString('base64')});
                return next();
            });
        });
    });

router.get('/status',
           function(req, res, next) {
               var message = { user: false,
                               admin: false,
                               loggedIn: false,
                               emailAddress: null,
                               firstName: null,
                               username: null,
                               timeout: 0 };
               var expirationDate = (new Date(req.session.cookie.expires)).getTime();
               var now = (new Date).getTime()

               if (req.session.hasOwnProperty('loggedIn') &&
                   req.session.hasOwnProperty('loggedInAdmin') &&
                   req.session.hasOwnProperty('loggedInUser') &&
                   req.session.hasOwnProperty('firstName') &&
                   req.session.hasOwnProperty('emailAddress') &&
                   req.session.hasOwnProperty('username')) {

                   message = {
                       user: req.session.loggedInUser,
                       admin: req.session.loggedInAdmin,
                       loggedIn: req.session.loggedIn &&
                           (now <= expirationDate),
                       emailAddress: req.session.emailAddress,
                       firstName: req.session.firstName,
                       username: req.session.username,
                       timeout: config.sessionAges['interactive']/1000,
                       sessionId: Buffer.from(req.sessionID).toString('base64')
                   }

                   if (req.session.hasOwnProperty('timeout')) {
                       message.timeout = req.session.timeout;
                   }
               }

               res.status(200).send(message);
           });

router.get("/logout", ensureAuthenticated, function(req, res, next) {
    var id = req.user.id;
    req.session.destroy(function(err) {
        req.logOut();
        findByIdFull(id, (err, user) => {
            if (err) {
                res.status(500).send({"errMsg": JSON.stringify(err)});
                return next();
            }

            if (user) {
                deleteUser(id, (err, user) => {

                    if (err) {
                        res.status(500).send({"errMsg": JSON.stringify(err)});
                        return next();
                    } else {
                        res.status(200).send({"message": "Logout successful"});
                        return next();
                    }
                });
            } else {
                res.status(500).send({"errMsg": "user not found"});
                return next();
            }
        });
    });
});

// The aws-serverless-express library creates a server and listens on a Unix
// Domain Socket for you, so you can remove the usual call to app.listen.
// app.listen(3000)
app.use(passport.initialize());
app.use(passport.session());
app.use('/', router)

// Export your express server so you can import it in the lambda function.
module.exports = app
