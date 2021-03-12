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
  let userId, eventBody, queryString, queryParams, response, caughtError

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

    // Allow for testing in the AWS console, where test events are not stringified.
    if (typeof event.body === 'object') {
      eventBody = event.body
    } else {
      eventBody = JSON.parse(event.body)
    }

    switch (eventBody.procedureName) {
      case 'ADD_PROBLEM_VOTE':
        queryString = 'call sandbox.add_problem_vote(_user_id := $1, _problem_id := $2, _signed_vote := $3)'
        queryParams = [userId, eventBody.problemId, eventBody.signedVote]
        break;
      case 'ADD_SOLUTION_VOTE':
        queryString = 'call sandbox.add_solution_vote(_user_id := $1, _solution_id := $2, _signed_vote := $3)'
        queryParams = [userId, eventBody.solutionId, eventBody.signedVote]
        break;
      case 'DELEGATE':
        queryString = 'call sandbox.delegate(_delegating_user_id := $1, _recipient_user_id := $2)'
        queryParams = [userId, eventBody.recipientUserId]
        break;
      case 'INSERT_PROBLEM':
        queryString = 'call sandbox.insert_problem(_problem_title := $1, _problem_description := $2, _problem_tags := $3)'
        queryParams = [eventBody.problemTitle, eventBody.problemDescription, eventBody.problemTags]
        break;
      case 'INSERT_PROBLEM_LINK':
        queryString = 'call sandbox.insert_problem_link(_problem_id := $1, _link_title := $2, _link_url := $3)'
        queryParams = [eventBody.problemId, eventBody.linkTitle, eventBody.linkUrl]
        break;
      case 'INSERT_SOLUTION':
        queryString = 'call sandbox.insert_solution(_problem_id := $1, _solution_title := $2, _solution_description := $3, _solution_tags := $4)'
        queryParams = [eventBody.problemId, eventBody.solutionTitle, eventBody.solutionDescription, eventBody.solutionTags]
        break;
      case 'INSERT_SOLUTION_LINK':
        queryString = 'call sandbox.insert_solution_link(_solution_id := $1, _link_title := $2, _link_url := $3)'
        queryParams = [eventBody.solutionId, eventBody.linkTitle, eventBody.linkUrl]
        break;
      case 'SIGNOUT':
        queryString = 'call sandbox.signout_user(_user_id := $1)'
        queryParams = [userId]
        break;
      case 'TEST':
        queryString = `update sandbox.users set signout_ts = signout_ts + (20 * interval '1 minute') where user_id = $1`
        queryParams = [3]
        break;
      default:
        throw (`[d365] Event body does not contain known procedure`);
    }

    // Query database.
    await client.query(queryString, queryParams)

    response = {
      "statusCode": 200,
      "statusDescription": "200 OK"
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
