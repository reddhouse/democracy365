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
  let queryString, result, caughtError

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

    // This function was invoked by EventBridge (cron job) with custom JSON text, so the event has far fewer properties than usual.
    switch (event.procedureName) {
      case 'AIRDROP':
        queryString = `call sandbox.airdrop()`
        break;
      case 'TEST':
        queryString = `update sandbox.users set signout_ts = signout_ts + (20 * interval '1 minute') where user_id = 3`
        break;
      default:
        throw (`Event body does not contain known procedure`);
    }

    // Query database.
    result = await client.query(queryString)

    // Test Dead Letter Queue with forced error
    // throw("Testing Dead Letter Queue")

  } catch (error) {
    caughtError = error
    console.log('BUMMER: ', error)
  }

  return new Promise((resolve, reject) => {
    // No need to resolve with a response as SQS won't process it anyway.
    caughtError ? reject(caughtError) : resolve(undefined)
  })
}
