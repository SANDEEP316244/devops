d = {}
d_1 = dict()

# Dictonaires are key:value pair based
# Also known as hashmaps

sample = {'a': 1, 'b': 2}
print(sample['a'], sample.get('b'))

# Dictionaries are mutable datatype
sample['a'] = 10
print(sample)

# Keys in dictonaries, once defined can't be changed
# Hence they should be of immutable datatype, for e.g. tuple, string
sample = {("a", "b"): 1, 'b': 2}
print(sample)

# print(dir(dict))

"""
['clear', 'copy', 'fromkeys', 'get', 'items', 'keys', 'pop', 'popitem', 'setdefault', 'update', 'values']
"""
print(sample.keys(), sample.values(), sample.items())

sample_list = [(('a', 'b'), 1), ('b', 2)]

# type casting
sample_dict = dict(sample_list)
print(sample_dict)