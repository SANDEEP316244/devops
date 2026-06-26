sample = "Hello, how are you doing?"
sample_1 = "abc" # ("a", "b", "c")
# print(sample[0])
# sample[0] = 'h'
# print(sample)

# print(dir(sample))

"""
['capitalize', 'casefold', 'center', 'count', 'encode', 'endswith', 'expandtabs', 'find', 'format', 'format_map', 'index', 'isalnum', 'isalpha', 'isascii', 'isdecimal', 'isdigit', 'isidentifier', 'islower', 'isnumeric', 'isprintable', 'isspace', 'istitle', 'isupper', 'join', 'ljust', 'lower', 'lstrip', 'maketrans', 'partition', 'removeprefix', 'removesuffix', 'replace', 'rfind', 'rindex', 'rjust', 'rpartition', 'rsplit', 'rstrip', 'split', 'splitlines', 'startswith', 'strip', 'swapcase', 'title', 'translate', 'upper', 'zfill']
"""
print(sample.casefold())
print(sample.center(100,"#"))

# Reverse string
print(sample[::-1])
print(tuple(sample_1), list(sample_1))

sample = "Hello, how are you doing?"
print(sample.split(" "))
print("#".join(sample.split(" ")))

# concatenation: joining 2 strings
print("a" + "#" + "b") # "ab"

# How do you print a file path
print("D:\Personal\DevOps\joindevops\daws-86s\python-basics\strings.py")