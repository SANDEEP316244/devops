sample = set() # {}
# print({'a', 'b', 'a'})
sample = {'a', 'b', 'a'}
print(sample)
# Sets are an unordered collection
# Sets removes duplicates and stores unqiue values

# print(dir(set()))

"""
['add', 'clear', 'copy', 'difference', 'difference_update', 'discard', 'intersection', 'intersection_update', 'isdisjoint', 'issubset', 'issuperset', 'pop', 'remove', 'symmetric_difference', 'symmetric_difference_update', 'union', 'update']
"""
sample.add(10)
print(sample)
# print(sample[0])
# Ordered collection (such as list, tuple, dict) supports indexing
# Unorded collection doesn't support indexing

s1 = {1, 2, 3, 4}
s2 = {2, 4, 6, 8}

print(s1.difference(s2))
s1.difference_update(s2)
print(s1)