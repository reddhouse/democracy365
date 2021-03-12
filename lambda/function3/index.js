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

const verifySig = (msg, sig) => {
  if (typeof kms === 'undefined') {
    kms = new AWS.KMS()
  }
  return kms.verify({
    Message: msg,
    KeyId: KMS_KEY_ID,
    Signature: sig,
    SigningAlgorithm: 'RSASSA_PKCS1_V1_5_SHA_256',
    MessageType: 'RAW'
  }).promise()
}

exports.handler = async (event) => {
  let response = { "isAuthorized": false }
  let userId, messageToBeVerified, hexSignature

  // Grab userId and signature from request's auth header.
  if (event && event.headers && event.headers.authorization) {
    userId = event.headers.authorization.split('.')[0]
    hexSignature = event.headers.authorization.split('.')[1]
  } else {
    return response
  }

  const queryString = 'select signin_code, signout_ts from sandbox.users where user_id = $1'
  const queryParams = [userId]

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

    // Query database.
    const result = await client.query(queryString, queryParams)
    if (result.rows.length == 0) {
      throw (`[d365] Query did not return any results for userId: ${queryParams[0]}`)
    } else {
      messageToBeVerified = `democracy365${result.rows[0].signin_code}${result.rows[0].signout_ts}`
    }

    // Verify signature.
    const verificationResponse = await verifySig(messageToBeVerified.toString(), Buffer.from(hexSignature, 'hex'))
    if (verificationResponse.SignatureValid == true) {
      response = {
        "isAuthorized": true,
        "context": { "userId": userId }
      }
    }

  } catch (error) {
    console.log('BUMMER: ', error)
    console.log('EVENT: ', JSON.stringify(event, null, 2))
    return response
  }

  return response
}
