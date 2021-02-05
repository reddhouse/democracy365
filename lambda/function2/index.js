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
  const queryString = `update sandbox.users set signout_ts = signout_ts + (20 * interval '1 minute') where user_id = 3`
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

    // Test Dead Letter Queue with forced error
    // throw("Testing Dead Letter Queue")

  } catch (error) {
    caughtError = error
    console.log('BUMMER: ', error)
  }

  // Test SQS queue trigger...
  if (event.Records) console.log(event.Records[0].body)

  return new Promise((resolve, reject) => {
    // No need to resolve with a response as SQS won't process it anyway.
    caughtError ? reject(caughtError) : resolve(undefined)
  })
}
