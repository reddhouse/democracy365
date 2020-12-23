const AWS = require('aws-sdk')

exports.handler = async (event) => {
  const { REGION, PROXY_HOST, DB_PORT, DB_USER, DB_NAME, KMS_KEY_ID } = process.env

  let caughtError

  try {

  } catch (err) {
    caughtError = err
    console.log('BUMMER: ', err)
  }

  let response = {
    "statusCode": 200,
    "statusDescription": "200 OK",
    "isBase64Encoded": false,
    "headers": { "Content-Type": "text/html" },
    "body": { "foo": "bar" }
  }

  return new Promise((resolve, reject) => {
    caughtError ? reject(caughtError) : resolve(response)
  })
}
