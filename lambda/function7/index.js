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
  let queryString, queryParams, caughtError

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

    // This function was invoked by EventBridge (cron job) with custom JSON text, so the event has fewer properties than usual.
    switch (event.procedureName) {
      case 'AIRDROP':
        queryString = 'call sandbox.airdrop()'
        queryParams = []
        break;
      case 'LOG_RANK_HISTORIES':
        queryString = 'call sandbox.log_rank_histories()'
        queryParams = []
        break;
      case 'REFRESH_PROBLEM_RANK':
        queryString = 'refresh materialized view concurrently sandbox.problem_rank'
        queryParams = []
        break;
      case 'REFRESH_SOLUTION_RANK':
        queryString = 'refresh materialized view concurrently sandbox.solution_rank'
        queryParams = []
        break;
      default:
        throw (`[d365] Event does not contain known procedure`);
    }

    // Query database.
    await client.query(queryString, queryParams)

  } catch (error) {
    caughtError = error
    console.log('BUMMER: ', error)
    console.log('EVENT: ', JSON.stringify(event, null, 2))
  }

  return new Promise((resolve, reject) => {
    // No need to resolve with a response as EventBridge won't process it anyway.
    caughtError ? reject(caughtError) : resolve(undefined)
  })
}
