# This is live currently on crypto.reddragon09.in

#  Automated Crypto Price Predictor Web App (AWS Production Pipeline)

DevOps implementation of a **Python/Flask** Machine Learning application that forecasts **Bitcoin and Ethereum** prices. This project uses **Terraform** for Infrastructure as Code (IaC) to dynamically provision and manage hidden cloud architecture in the **AWS Stockholm (`eu-north-1`) region**.

---

## Cloud Architecture 
* **Hosting Compute Layer:** AWS ECS Express Mode.
* **Database Layer:** AWS RDS MySQL Instance completely isolated inside a hidden private VPC network subnet.
* **Network & Security Controls:** Custom AWS Security Groups acting as stateful firewalls. The container runs via a heavily restricted, unprivileged non-root system identity (`USER appuser`) inside the Docker wrapper layer.
* **Continuous Integration & Deployment:** GitHub Actions orchestrating automated image builds and infrastructure apply pipelines on every push.

---

##  How to Deploy This to Your Own AWS Account

### 1. Prerequisites
* A registered domain configured via an **AWS Route 53 Hosted Zone** (e.g., `yourdomain.com`).
* An AWS IAM deployment user account(having `AdminstratorAccess` policy for terraform) with programmatic access keys (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`).
* Unique S3 bucket name
 
### 2. Configure GitHub Secrets
Fork or copy this repository, navigate to **Settings ➡️ Secrets and variables ➡️ Actions**, and add these **4 Encrypted Secrets** to repository secrets:
* `AWS_ACCESS_KEY_ID` - Your programmatic IAM access ID string.
* `AWS_SECRET_ACCESS_KEY` - Your matching programmatic secret access key.
* `MY_ROOT_DOMAIN` - Your base hosted zone domain name (e.g., `mydomain.com`).
* `MY_SUBDOMAIN` - The subdomain address where the web app will be served (e.g., `abc.mydomain.com`). (Do not enter only the subdomain (e.g., `abc`) as the secret value)

### 3. Change S3 Bucket Name
* Go to main.tf and change the S3 bucket name for backend located within the first terrafrom{...} block to a different unique name.
* Go to .github/workflows/deploy.yml file and change the bucket name in the Remote state storage section (step 4) to the same name used in main.tf.

### 4. Push and Launch!
Once your secrets are added, push your project modifications to the main branch:
```bash
git add .
git commit -m "intial message"
git push origin main
```
The **GitHub Actions pipeline** will automatically fire up, invoke Terraform, deploy your isolated database, create your tracking tables, compile your hardened container image, and route it to your custom domain address with live HTTPS enabled!

The database created will be empty so ensure you create an user via the registration page rather than trying to find default user login details.
