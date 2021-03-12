const AWS = require('aws-sdk')
const { Client } = require('pg')
const { promisify } = require('util')

// DB_HOST and DB_PASSWORD should be deleted once proxy goes live.
const { REGION, DB_HOST, DB_PASSWORD, PROXY_HOST, DB_PORT, DB_USER, DB_NAME, TEST_EMAIL_ADDR } = process.env
let client

const getRDSToken = () => {
  const signer = new AWS.RDS.Signer({
    region: REGION,
    hostname: PROXY_HOST,
    port: Number(DB_PORT),
    username: DB_USER
  })
  return promisify(signer.getAuthToken).bind(signer)
}

const clientConfig = (rdsToken) => {
  return {
    host: PROXY_HOST,
    database: DB_NAME,
    port: DB_PORT,
    user: DB_USER,
    password: rdsToken,
    ssl: true
  }
}

const sendEmail = (signinCode) => {
  const ses = new AWS.SES()
  let params = {
    Destination: { ToAddresses: [TEST_EMAIL_ADDR] },
    Message: {
      Body: {
        Html: {
          Data: `<html><body><p>This is your secret login code:</p><h3>${signinCode}</h3></body></html>`,
          Charset: 'UTF-8'
        },
        Text: {
          Data: `Your secret login code: ${signinCode}`,
          Charset: 'UTF-8'
        }
      },
      Subject: {
        Data: 'Your secret login code',
        Charset: 'UTF-8'
      }
    },
    Source: TEST_EMAIL_ADDR
    // ReplyToAddresses: ['STRING_VALUE'],
  }
  return ses.sendEmail(params).promise()
}

exports.handler = async (event) => {
  let queryString, queryParams, result, userId, signinCode, response, caughtError

  try {
    // Establish database connection with attempted reuse of execution context.
    if (typeof client === 'undefined') {
      // Uncomment once proxy goes live.
      // const rdsToken = await getRDSToken()
      // client = new Client(clientConfig(rdsToken))

      // Delete and make use of connection method above, once proxy goes live.
      client = new Client({
        host: DB_HOST,
        database: DB_NAME,
        port: DB_PORT,
        user: DB_USER,
        password: DB_PASSWORD
      })

      await client.connect()
    }

    queryString = 'select user_id, signin_code from sandbox.users where email_address = $1'
    queryParams = [JSON.parse(event.body).emailAddress]

    // Query database.
    result = await client.query(queryString, queryParams)
    if (result.rows.length == 0) {
      throw (`[d365] Query did not return any results for email address: ${queryParams[0]}`)
    } else {
      userId = result.rows[0].user_id
      signinCode = result.rows[0].signin_code
    }

    // Send email with signin code.
    await sendEmail(signinCode)

    // Send back userId, as subsequent requests will use userId instead of email address to identify user.
    response = {
      "statusCode": 200,
      "statusDescription": "200 OK",
      "isBase64Encoded": false,
      "headers": { "Content-Type": "text/html" },
      "body": JSON.stringify({ "userId": userId })
    }

  } catch (error) {
    caughtError = error
    console.log('BUMMER: ', error)
    console.log('EVENT: ', JSON.stringify(event, null, 2))
  }

  return new Promise((resolve, reject) => {
    caughtError ? reject(caughtError) : resolve(response)
  })
}
