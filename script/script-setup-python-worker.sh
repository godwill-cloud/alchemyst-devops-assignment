```bash
#!/bin/bash
sudo yum update -y
sudo yum install python3 git -y

cd /home/ec2-user

git clone https://github.com/iii-org/quickstart.git
cd quickstart

pip3 install -r requirements.txt
python3 worker.py
```

---