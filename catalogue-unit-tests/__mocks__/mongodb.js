module.exports = {
  MongoClient: {
    connect: jest.fn().mockResolvedValue({
      db: () => ({
        collection: () => ({
          find: (query) => {
            if (query && query.categories) {
              // simulate category filter
              return {
                sort: () => ({
                  toArray: () => Promise.resolve([{ sku: '123', categories: query.categories }])
                })
              };
            }
            return {
              sort: () => ({
                toArray: () => Promise.resolve([{ sku: '123', name: 'Mock Product' }])
              }),
              toArray: () => Promise.resolve([{ sku: '123', name: 'Mock Product' }])
            };
          },
          findOne: () => Promise.resolve({ sku: '123', name: 'Mock Product' }),
          distinct: () => Promise.resolve(['cat1', 'cat2'])
        })
      })
    })
  },
  ObjectId: jest.fn()
};