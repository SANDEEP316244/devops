# 🐧 Shell Scripting Practice Problems

## 📂 Problems

**NOTE:** You can find the supporting files in this repo

### 1. File Existence & Permissions
Write a script that accepts a filename (or path) as a **command-line argument** and prints whether:  
- The file exists  
- It is **readable**  
- It is **writable**  
- Or it is **not present**  

👉 **Extension**: If the argument is a **directory**, list all files inside it.

---

### 2. Count Lines, Words, and Characters
Write a script that accepts a filename and prints:  
- The **number of lines**  
- The **number of words**  
- The **number of characters**  

⚠️ Handle edge cases:  
- Empty file  
- Non-existent file  
- Permission denied  

---

### 3. String Replacement in Files
Write a script that replaces all occurrences of a string in multiple files.

- Replace the string `FOO` with `BAR` in all `.conf` files in a given directory and its subdirectories.  
- Use `find` + `sed` (or `perl -pi`).

---

### 4. Filter Lines from a File
Write a script that reads a large CSV/log file **line by line** and filters all lines that contain the word `ERROR`.  
- Save those lines into a separate output file.  
- Include a **header line** in the output.

---

### 5. Largest Number from Arguments
Write a script that finds the **largest number** from a list of numbers provided as **command-line arguments**.  

Example:
```bash
./largest.sh 12 56 3 89 42
# Output: Largest number is 89
```

### 6. Random Password Generator
Write a script that generates a **random password** of a specified length.  
- The password should contain uppercase, lowercase, digits, and special characters.  
- Input: password length.  
- Output: random password string.

---

### 7. Word Frequency Counter
Write a script that reads a file and prints the **top 5 most repeated words** in that file, along with the **number of times** each word appears.

---

### 8. Fibonacci Series
Write a script that prints the **Fibonacci series** up to `N` terms.  

Example for `N=7`:


---

### 9. Palindrome Check
Write a script that checks if a given **string or number** is a palindrome.  

Examples:
- `madam` → Palindrome  
- `12321` → Palindrome  
- `hello` → Not a Palindrome  

---

### 10. Prime Number Check
Write a script that checks whether a given number is **prime or not**.

---

### 11. Factorial of a Number
Write a script that calculates the **factorial** of a given number.  

Example:
- Input: `5` → Output: `120`

---

### 12. Pyramid of Stars
Write a script that prints a **pyramid of stars** with 5 lines.

Example:
```
    *
   ***
  *****
 *******
*********
```