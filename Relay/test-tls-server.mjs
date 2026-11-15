// Local test fixture only. Certificates/keys are generated in a temporary directory by the test script.
import https from 'node:https';
import {readFileSync} from 'node:fs';
import {createRelay} from './server.mjs';
const server = createRelay({serverFactory: handler => https.createServer({
  key: readFileSync(process.argv[2]), cert: readFileSync(process.argv[3]),
}, handler)});
server.listen(0, '127.0.0.1', () => console.log(server.address().port));
process.on('SIGTERM', () => server.close(() => process.exit(0)));
