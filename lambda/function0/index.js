exports.handler = async function (event) {
  console.log("d365Event: ", JSON.stringify(event, null, 2))
  const response = {
    statusCode: 200,
    body: JSON.stringify('Got Lambda?')
  }
  return response
}
