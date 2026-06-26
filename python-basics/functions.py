# def func_name():
#     print("Hello")

# print(func_name())

# def mult(a, b, *args, **kwargs):
#     # *args -> pass any no: of position arguments
#     # **kwargs -> pass any no: keyword arguments
#     print(f"a:{a}, b:{b}, args:{args}, kwargs:{kwargs}")
#     return a * b # default is None

# a=4, b=5 are keyword arguments, as they contains keys and values
# '3.0', 3 are called as positional arguments
# res = mult('3.0', 3, 4, 5, c=10, d=20)
# print(res)

"""
When we specify data type in function but if we give different data type when passing the values what happen
"""

# def abc(a:int, b:float) -> float:
#     return a + b
# print(abc(1, 2.0))


def calc(a, b, operation):
    if operation == "add":
        return a + b
    if operation == "sub":
        return a - b
    if operation == "mult":
        return a * b
    if operation == "div":
        return a % b

# def sample(var):
#     return int(var) + 1
# values = list(map(sample, input("Enter 2 numbers: ").split()))

a, b = tuple(map(int, input("Enter 2 numbers: ").split()))
operation = input("Enter operation to perform (add, sub, mult, div): ")
res = calc(a, b, operation)
print(res)