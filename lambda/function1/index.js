const AWS = require('aws-sdk')
const { Client } = require('pg')
const { promisify } = require('util')

const { REGION, PROXY_HOST, DB_PORT, DB_USER, DB_NAME } = process.env
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
  //const eventBody = JSON.parse(event.body)
  const queryString = 'select * from sandbox.users'
  let result, caughtError

  try {
    // Establish database connection with attempted reuse of execution context.
    if (typeof client === 'undefined') {
      const rdsToken = await getRDSToken()
      client = new Client(clientConfig(rdsToken))
      await client.connect()
    }

    // Query database.
    result = await client.query(queryString)

  } catch (error) {
    caughtError = error
    console.log('BUMMER: ', error)
  }

  const response = {
    "statusCode": 200,
    "statusDescription": "200 OK",
    "isBase64Encoded": false,
    "headers": { "Content-Type": "text/html" },
    "body": JSON.stringify(result.rows)
  }

  return new Promise((resolve, reject) => {
    caughtError ? reject(caughtError) : resolve(response)
  })
}
