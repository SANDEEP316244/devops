Custom module
Open source module
We can use direct resource definitions

1. Project Infra -> One time infra
2. Application Infra -> frequent changes

Client -> BA -> Enable whatsapp banking

Delivery Manager -> TCS side delivery manager
Teams -> frontend, backend, database, L1, L2, reports, monitoring, qa etc
Team manager -> frontend manager, backend manager, etc.
Team Lead
Team
Team members

if frontend work -> frontend team manager -> frontend team lead -> team members

team == target group == a group of members == a group of instances
member == ec2 instance
availability check == health check
every 5 sec once check this URL, if getting response it means available
for example continous 3 health checks failure, then NA

http://catalogue.daws86s.fun:8080/health

delivery manager/team manager/lead == load balancer

if catalogue component work forward to catalogue team/target group

rules -> catalogue.daws86s.fun -> forward to catalogue target group
	  -> shipping.daws86s.fun -> forward to shipping target group
	  
load balancer
rules
target group
health check
instance
listener -> frontend load balancer(public) 80/443, backend load balancer(private) 8080

http://daws86s.fun -> port no 80

http://daws86s.fun:90

https://daws86s.fun -> port no 443

StringList == Separate strings using commas.

siva, kumar, reddy, m

["siva","kumar","reddy","m"]
convert list to string in terraform

join and split

join -> join the elements in list as single string with seperator

subnet-0b74d14411866ada1,subnet-01c3ab188edc1bb04

siva kumar reddy m