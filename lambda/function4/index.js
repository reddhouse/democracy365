const AWS = require('aws-sdk')
const { Client } = require('pg')
const { promisify } = require('util')

const { REGION, PROXY_HOST, DB_PORT, DB_USER, DB_NAME, TEST_EMAIL_ADDR } = process.env
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
  const eventBody = JSON.parse(event.body)
  const queryString = `select user_id, signin_code from sandbox.users where email_address = '${eventBody.emailAddress}'`
  let userId, signinCode, caughtError

  try {
    // Establish database connection with attempted reuse of execution context.
    if (typeof client === 'undefined') {
      const rdsToken = await getRDSToken()
      client = new Client(clientConfig(rdsToken))
      await client.connect()
    }

    // Query database.
    const result = await client.query(queryString)
    userId = result.rows[0].user_id
    signinCode = result.rows[0].signin_code

    // Send email with signin code.
    await sendEmail(signinCode)

  } catch (error) {
    caughtError = error
    console.log('BUMMER: ', error)
  }

  // Future requests will use userId instead of email address to identify user.
  const response = {
    "statusCode": 200,
    "statusDescription": "200 OK",
    "isBase64Encoded": false,
    "headers": { "Content-Type": "text/html" },
    "body": JSON.stringify({ "userId": userId })
  }

  return new Promise((resolve, reject) => {
    caughtError ? reject(caughtError) : resolve(response)
  })
}
