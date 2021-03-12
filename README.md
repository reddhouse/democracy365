# democracy365
<div align="right"><b><i>Participate or delegate!</b></i></div>

## Api Routes
/public\
/read [requires auth]\
/write [requires auth]\
/signin1\
/signin2\
/signup

<br>

## Lambda Functions
| name | description | invoked by |
| --- | --- | --- |
| function0 | public reads to db | api gateway |
| function1 | private reads to db | api gateway |
| function2 | private writes to db | api gateway |
| function3 | lambda authorizer | api gateway, access control |
| function4 | sign in 1, get user_id from db, send email with code | api gateway |
| function5 | sign in 2, verify code, issue token | api gateway |
| function6 | signup | api gateway |
| function7 | scheduled events handler | eventbridge |
| function99 | sandbox | console |

<br>
