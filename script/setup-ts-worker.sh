```bash
#!/bin/bash
sudo yum update -y
sudo yum install git docker -y
sudo service docker start

curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo bash -
sudo yum install -y nodejs

cd /home/ec2-user

git clone https://github.com/iii-org/quickstart.git
cd quickstart

npm install
npm run worker
```

---