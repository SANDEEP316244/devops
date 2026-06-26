l = []
l1 = list()

server_1 = "172.10.33.25"
server_2 = "172.10.33.26"

servers = ["172.10.33.25", "172.10.33.26", True, 123, 1234.56, 1234.567]
# print(type(servers), servers, server_1, server_2)
print(servers)

# Python is zero indexed based
server_1 = servers[0]
# print("Server 1 IP address:",server_1)

# Slicing (start_index:end_index + 1:step_size), as end_index in python is not inclusive
# step_size: 1 (default)
simple_slice = servers[1:6:2] # [1, 1+2, 3+2, 5+2]
simple_slice = servers[1:]
print(simple_slice)
simple_slice = servers[:5]
print(simple_slice)
simple_slice = servers[:]
print(simple_slice)

# Negative indexing
simple_slice = servers[-1:-4:-1]
# print(simple_slice)

# print("Length of list:", len(simple_slice))

# List is a mutable datatype
# Mutable: Once defined, can change at any time E.g. List, dictonaries
# Immutable: Once defined, can't be changed E.g. Tuple, sets

# print("Before modify:", servers)
servers[-3] = 1234 # Inplace operation
# print("After modification:", servers)

# print("List of operations:", dir(servers))

"""
['append', 'clear', 'copy', 'count', 'extend', 'index', 'insert', 'pop', 'remove', 'reverse', 'sort']
"""
servers = ["172.10.33.25", "172.10.33.26", True, 123, 1234.56, 1234.567, True]
print("Before:", servers)
servers.append(False)
print("After:", servers)
servers.append(["a", "b"])
print("After append:", servers, len(servers))
# Multi indexing
# print(servers[-1][0])
servers.extend(["c", "d"])
print("After extend:", servers, len(servers))
print(servers.index(True))
servers.insert(0, 12)
print(servers)
servers.remove(True)
print(servers)
servers.reverse()
print(servers)
servers = servers[::-1]
print(servers)

servers = [1, 5, 7, 9, 2, 4, 3]
# servers.sort()
servers_1 = sorted(servers)
print(servers, servers_1)

servers = ["172.10.33.25", "172.10.33.26", True, 123, 1234.56, 1234.567, True]
servers_1 = servers.copy()
servers_1.remove(123)
print(servers, servers_1)

"""
1. Reverse a list
2. Sort vs sorted
3. Integer division vs floor division
4. Shallow copy (inplace operation)
5. Multi indexing
6. append vs extend
7. Mutable vs immutable
8. dir()
"""

servers_1.remove(123456)