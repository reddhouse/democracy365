# democracy365
Participate or delegate!

## lambda - description [invoked by]
function1  - read [api gateway]  
function2  - write [sqs]  
function3  - lambda authorizer [api gateway, access control]  
function4  - sign in 1, get userId from db, send email with code [api gateway]  
function5  - sign in 2, verify code, issue token [api gateway]  
function99 - sandbox [console]  
