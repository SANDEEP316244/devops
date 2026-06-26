### Jenkins Setup

Installation commands from Jenkins official doc
```
sudo curl -o /etc/yum.repos.d/jenkins.repo \
    https://pkg.jenkins.io/redhat-stable/jenkins.repo
sudo rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
# Add required dependencies for the jenkins package
sudo yum install fontconfig java-21-openjdk -y
sudo yum install jenkins -y
sudo systemctl daemon-reload
sudo systemctl start jenkins
sudo systemctl enable jenkins
```

#### Plugins:
* Stage view
* AWS Steps
* SonarQube scanner
* Pipeline utility steps

#### Master Agent Architecture
* Create credentials to connect agent
* Install Java in agent
* Select Non verification strategy

#### Credentials
* SSH authentication
* AWS credentials
* Sonar token

# Sonar

### 🐞 Bugs

An issue representing a coding error that will likely cause unexpected behavior or application failure. This seems fine but sometimes it may break in production.

### 🔐 Vulnerabilities
A security-related holes that can be exploited by attackers. This can be hacked

### 👃 Code Smells
A maintainability issue that does not break the app but makes the code hard to understand, change, or maintain. This works today, but hurts tomorrow

**Technical Debt:**
It is the estimated time required to fix all maintainability issues (code smells) in the codebase. That future pain = technical debt

**Example:**
Your project has:
100 code smells
Each smell estimated as 10 minutes to fix
```
Technical Debt = 100 × 10 min = 1000 minutes ≈ 16.6 hours
```

Example timings SonarQube assumes: <br/>
Rename variable → 2 min <br/>
Reduce complexity → 30 min <br/>
Remove duplication → 1h

### 📋 Duplication
Percentage or blocks of identical or near-identical code across files. copy-paste risk. Should be made as function and reuse it.

### 📊 Coverage

Percentage of code that is executed by unit tests.
```
Coverage = (Lines covered by tests / Lines to cover) × 100
```

Unit testing will give us a JSON report
* Total test cases executed
* How many passed, How many failed

This report should be uploaded to SonarQube server through agent.

### 🔒 Security Rating
Rating based on severity of vulnerabilities

**Ratings logic:**
A → No vulnerabilities
B–E → Based on highest severity found

Example:
1 Critical vulnerability → Rating becomes E <br/>
Security Rating = worst vulnerability decides

### 🛠️ Maintainability Rating

Rating based on Technical Debt Ratio
Technical Debt Ratio formula:
```
(Total remediation cost / Development cost) × 100
```
1️⃣ Total Remediation Cost (SonarQube)
What it means
Example:
Total time required to fix all Code Smells in the codebase.
| Code Smell        | Fix Time |
| ----------------- | -------- |
| Long method       | 30 min   |
| Duplicate code    | 1 hour   |
| Bad variable name | 2 min    |

```
Total remediation cost = 1h 32m
```

2️⃣ Development Cost (SonarQube)
What it means?
Estimated time it would take to write the existing code from scratch.
SonarQube uses a fixed heuristic:
Development cost = Lines of Code × 30 minutes
(30 minutes per line is SonarQube’s default assumption)

Example

Lines of Code: 1,000
```
Development cost = 1,000 × 30 min = 30,000 min ≈ 500 hours
```

**Real Example:**
Lines of Code: 2,000

Development cost = 2,000 × 30 min = 1,000 hours
Total remediation cost = 50 hours
```
Technical Debt Ratio = (50 / 1000) × 100 = 5%
```
**Ratings:**
A → ≤ 5%

B → 6–10%

C → 11–20%

D → 21–50%

E → > 50%

Driven mainly by:

Code smells

Complexity

Duplication

➡️ Maintainability Rating = future change effort

### 🎯 Reliability Rating

Rating based on Bugs severity

Blocker/Critical bugs push rating down fast

➡️ Reliability = stability of the app