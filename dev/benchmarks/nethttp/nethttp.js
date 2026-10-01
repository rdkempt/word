const http = require('http');

function once() {
  return new Promise((resolve, reject) => {
    http.get({ host: '127.0.0.1', port: 4491, path: '/p', agent: false }, (res) => {
      let n = 0;
      res.on('data', (c) => { n += c.length; });
      res.on('end', () => resolve(n));
    }).on('error', reject);
  });
}

(async () => {
  let total = 0;
  for (let i = 0; i < 200; i++) total += await once();
  console.log(total);
})();
