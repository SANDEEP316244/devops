const app = require('./server');
const pino = require('pino');

const logger = pino({
  level: 'info',
  prettyPrint: false,
  useLevelLabels: true
});

const port = process.env.CATALOGUE_SERVER_PORT || '8080';
app.listen(port, () => {
  logger.info('Started on port', port);
});