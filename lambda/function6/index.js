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
          Data: `<html><body>
                  <p>Welcome to democracy365!</p>
                  <p>Please use the following code when you sign in to your account:</p>
                  <h3>${signinCode}</h3>
                </body></html>`,
          Charset: 'UTF-8'
        },
        Text: {
          Data: `Welcome to democracy365. Your secret login code is: ${signinCode}`,
          Charset: 'UTF-8'
        }
      },
      Subject: {
        Data: 'Welcome to democracy365',
        Charset: 'UTF-8'
      }
    },
    Source: TEST_EMAIL_ADDR
    // ReplyToAddresses: ['STRING_VALUE'],
  }
  return ses.sendEmail(params).promise()
}

exports.handler = async (event) => {
  let eventBody, queryString, queryParams, result, userId, signinCode, response, caughtError

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

    eventBody = JSON.parse(event.body)
    queryString = 'call sandbox.insert_new_user(_email_address := $1)'
    queryParams = [eventBody.emailAddress]

    // Add email address to database. Postgres will throw an error if it's not unique.
    await client.query(queryString, queryParams)

    // Go ahead and grab user_id and signin_code to send to new user. This bypasses step 1 of the normal sign-in flow, keeping emails to a minimum.
    queryString = 'select user_id, signin_code from sandbox.users where email_address = $1'
    queryParams = [eventBody.emailAddress]
    result = await client.query(queryString, queryParams)
    if (result.rows.length == 0) {
      throw (`[d365] Query to retrieve signin_code did not return any results for email address: ${queryParams[0]}`)
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
