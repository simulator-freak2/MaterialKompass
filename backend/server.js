const { createApp } = require('./src/app');

const app = createApp();
const port = process.env.PORT || 3000;

app.listen(port, () => {
  console.log(`MaterialKompass backend listening on http://localhost:${port}`);
});
