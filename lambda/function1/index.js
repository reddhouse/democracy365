const AWS = require('aws-sdk')
const { Client } = require('pg')
const { promisify } = require('util')

exports.handler = async (event) => {
  const { REGION, PROXY_HOST, DB_PORT, DB_USER, DB_NAME } = process.env

  const createToken = () => {
    const signer = new AWS.RDS.Signer({
      region: REGION,
      hostname: PROXY_HOST,
      port: Number(DB_PORT),
      username: DB_USER
    })
    return promisify(signer.getAuthToken).bind(signer)
  }

  let clientConfig = (token) => {
    return {
      host: PROXY_HOST,
      database: DB_NAME,
      port: DB_PORT,
      user: DB_USER,
      password: token,
      ssl: true
    }
  }

  let queryString = 'select * from sandbox.accounts'
  // let queryString = 'update sandbox.accounts set balance = balance + 1000 where id = 3'
  let formattedResult
  let caughtError

  try {
    let token = await createToken()
    let client = new Client(clientConfig(token))
    await client.connect()
    let result = await client.query(queryString)
    formattedResult = JSON.stringify(result.rows)
    await client.end()

  } catch (err) {
    caughtError = err
    console.log('Bummer: ', err)
  }

  let response = {
    "statusCode": 200,
    "statusDescription": "200 OK",
    "isBase64Encoded": false,
    "headers": { "Content-Type": "text/html" },
    "body": formattedResult
  }

  // Test SQS queue trigger...
  if (event.Records) console.log(event.Records[0].body)

  return new Promise((resolve, reject) => {
    caughtError ? reject(caughtError) : resolve(response)
  })
}
