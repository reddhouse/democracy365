const AWS = require('aws-sdk')
const { Client } = require('pg')
const { promisify } = require('util')

// DB_HOST and DB_PASSWORD should be deleted once proxy goes live.
const { REGION, DB_HOST, DB_PASSWORD, PROXY_HOST, DB_PORT, DB_USER, DB_NAME } = process.env
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

exports.handler = async (event) => {
  let userId, queryString, queryParams, result, response, caughtError

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

    userId = event.requestContext.authorizer.lambda.userId

    switch (event.queryStringParameters && event.queryStringParameters.procedureName) {
      case 'TEST':
        queryString = 'select user_id, num_d365_tokens, signout_ts from sandbox.users where user_id = $1'
        queryParams = [event.queryStringParameters.testUser]
        break;
      default:
        throw (`[d365] Query string parameters are missing, or do not contain known procedure`);
    }

    // Query database.
    result = await client.query(queryString, queryParams)

    response = {
      "statusCode": 200,
      "statusDescription": "200 OK",
      "isBase64Encoded": false,
      "headers": { "Content-Type": "text/html" },
      "body": JSON.stringify(result.rows)
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
