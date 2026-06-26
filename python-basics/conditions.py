# Python is case sensitive i.e. 'a' and "A" are different
enviornment = input("Enter your envionment: ")
print(type(enviornment))
change_ticket = False

enviornment = enviornment.casefold()

if enviornment == "prod":
    change_ticket = True
    print("Please provide a change ticket")
elif enviornment == "staging":
    print("Welcome to staging environment")
else:
    print("Please login using your credentials")