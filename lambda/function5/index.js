const AWS = require('aws-sdk')
const { Client } = require('pg')
const { promisify } = require('util')

// DB_HOST and DB_PASSWORD should be deleted once proxy goes live.
const { REGION, DB_HOST, DB_PASSWORD, PROXY_HOST, DB_PORT, DB_USER, DB_NAME, KMS_KEY_ID } = process.env
let client, kms

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

const signMessage = (msg) => {
  if (typeof kms === 'undefined') {
    kms = new AWS.KMS()
  }
  return kms.sign({
    Message: msg,
    KeyId: KMS_KEY_ID,
    SigningAlgorithm: 'RSASSA_PKCS1_V1_5_SHA_256',
    MessageType: 'RAW'
  }).promise()
}

exports.handler = async (event) => {
  let eventBody, queryString, queryParams, result, signinCode, signoutTs, authToken, response, caughtError

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
    queryString = 'select signin_code, signout_ts from sandbox.users where user_id = $1'
    queryParams = [eventBody.userId]

    // Query database.
    result = await client.query(queryString, queryParams)
    if (result.rows.length == 0) {
      throw (`[d365] Query did not return any results for userId: ${queryParams[0]}`)
    } else {
      signinCode = result.rows[0].signin_code
      signoutTs = result.rows[0].signout_ts
    }

    // Throw error if codes do not match.
    if (eventBody.signinCode != signinCode) {
      throw '[d365] Invalid Signin Code'
    }

    // Create authToken by signing custom string and prefixing with userId
    const signedMessage = await signMessage(`democracy365${signinCode}${signoutTs}`)
    const hexSignature = signedMessage.Signature.toString('hex')
    authToken = `${eventBody.userId}.${hexSignature}`

    response = {
      "statusCode": 200,
      "statusDescription": "200 OK",
      "isBase64Encoded": false,
      "headers": { "Content-Type": "text/html" },
      "body": JSON.stringify({ "authToken": authToken })
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
