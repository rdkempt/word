const https = require('https');

function once() {
  return new Promise((resolve, reject) => {
    https.get({
      host: '127.0.0.1', port: 4492, path: '/p',
      agent: false, rejectUnauthorized: false,
    }, (res) => {
      let n = 0;
      res.on('data', (c) => { n += c.length; });
      res.on('end', () => resolve(n));
    }).on('error', reject);
  });
}

(async () => {
  let total = 0;
  for (let i = 0; i < 20; i++) total += await once();
  console.log(total);
})();
