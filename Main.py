from flask import Flask, render_template, request, redirect, url_for, session,send_from_directory
import yfinance as yf
import os
import pymysql
import pandas as pd 
import numpy as np
import io
import base64
import random
from sklearn.preprocessing import MinMaxScaler
from sklearn.metrics import mean_squared_error
from sklearn.ensemble import RandomForestRegressor, VotingRegressor
from sklearn.tree import DecisionTreeRegressor
from sklearn.ensemble import GradientBoostingRegressor
from datetime import date, timedelta

DB_HOST = os.environ.get('DB_HOST', '127.0.0.1')
DB_USER = os.environ.get('DB_USER', 'root')
DB_PASSWORD = os.environ.get('DB_PASSWORD', 'root')
DB_NAME = os.environ.get('DB_NAME', 'bitcoin')
def init_production_db():
    import pymysql
    import time

    for attempt in range(5):
        try:
            db_connect = pymysql.connect(
                host=os.environ.get('DB_HOST', '127.0.0.1'),
                user=os.environ.get('DB_USER', 'root'),
                password=os.environ.get('DB_PASSWORD', 'root'),
                database=os.environ.get('DB_NAME', 'bitcoin'),
                charset='utf8'
            )
            with db_connect:
                cursor = db_connect.cursor()
                # Run the exact schema structure defined in your original db.txt blueprint
                cursor.execute("""
                    CREATE TABLE IF NOT EXISTS signup (
                        username VARCHAR(50) NOT NULL PRIMARY KEY,
                        password VARCHAR(50) NOT NULL,
                        contact_no VARCHAR(15) NOT NULL,
                        email VARCHAR(50) NOT NULL,
                        address VARCHAR(80) NOT NULL
                    );
                """)
                db_connect.commit()
            print("Successfully verified and seeded production database tables!")
            break
        except Exception as e:
            print(f"Database connection attempt {attempt + 1} failed. Retrying in 5s... Error: {e}")
            time.sleep(5)
init_production_db()

app = Flask(__name__)

app.secret_key = 'welcome'

def train_model(symbol):
    end_date = date.today()
    start_date = end_date - timedelta(days=730)

    df = yf.download(symbol, start=start_date, end=end_date)
    df = df.reset_index()
    df['year'] = df['Date'].dt.year
    df['month'] = df['Date'].dt.month
    df['day'] = df['Date'].dt.day

    X = df[['year', 'month', 'day']]
    Y = df['Close'].values.reshape(-1, 1)

    features_scaler = MinMaxScaler()
    target_scaler = MinMaxScaler()
    X_scaled = features_scaler.fit_transform(X)
    Y_scaled = target_scaler.fit_transform(Y)

    rf = RandomForestRegressor()
    dt = DecisionTreeRegressor()
    gb = GradientBoostingRegressor()
    voting = VotingRegressor(estimators=[('rf', rf), ('dt', dt), ('gb', gb)])
    voting.fit(X_scaled, Y_scaled)

    return voting, features_scaler, target_scaler


@app.route('/PredictPricesAction', methods=['GET', 'POST'])
def PredictPricesAction():
    if request.method == 'POST':
        import yfinance as yf
        from datetime import date, timedelta

        symbol = request.form['t1'].strip()
        num_days = int(request.form['t2'].strip())

        # Map user-friendly name to ticker
        ticker_map = {
            'Bitcoin': 'BTC-USD',
            'ETH': 'ETH-USD'
        }

        ticker = ticker_map.get(symbol)
        if not ticker:
            return render_template('UserScreen.html', data="Invalid symbol selected.")

        # Fetch 1 year of historical data from today
        end_date = date.today()
        start_date = end_date - timedelta(days=365)
        df = yf.download(ticker, start=start_date, end=end_date)

        if df.empty:
            return render_template('UserScreen.html', data="Failed to fetch data for selected symbol.")

        df = df.reset_index()
        df['year'] = df['Date'].dt.year
        df['month'] = df['Date'].dt.month
        df['day'] = df['Date'].dt.day

        # Prepare dataset
        X = df[['year', 'month', 'day']]
        Y = df['Close'].values.reshape(-1, 1)

        # Normalize
        features_scaler = MinMaxScaler()
        target_scaler = MinMaxScaler()
        X_scaled = features_scaler.fit_transform(X)
        Y_scaled = target_scaler.fit_transform(Y)

        # Train model
        rf = RandomForestRegressor()
        dt = DecisionTreeRegressor()
        gb = GradientBoostingRegressor()
        voting = VotingRegressor(estimators=[('rf', rf), ('dt', dt), ('gb', gb)])
        voting.fit(X_scaled, Y_scaled)

        # Generate future dates
        future_data = []
        current_date = date.today()
        for i in range(num_days):
            future = current_date + timedelta(days=i+1)
            future_data.append([future.year, future.month, future.day])

        future_scaled = features_scaler.transform(future_data)
        predictions_scaled = voting.predict(future_scaled)
        predictions = target_scaler.inverse_transform(predictions_scaled.reshape(-1, 1))

        # Render predictions in HTML
        output = '<table border="1" align="center" width="100%" style="text-align: center;">'
        output += '<tr><th>Day No</th><th>Future Date</th><th>Predicted Price (USD)</th></tr>'
        for i, price in enumerate(predictions):
            future = current_date + timedelta(days=i+1)
            output += f'<tr><td>{i+1}</td><td>{future}</td><td>{round(price[0], 2)}</td></tr>'
        output += '</table><br><br>'

        labels = [str(current_date + timedelta(days=i+1)) for i in range(num_days)]
        prices = [round(p[0], 2) for p in predictions]

        return render_template('UserScreen.html', data=output, labels=labels, prices=prices, coin=symbol)

@app.route('/RegisterAction', methods=['GET', 'POST'])
def RegisterAction():
    if request.method == 'POST':
        username = request.form['t1']
        password = request.form['t2']
        contact = request.form['t3']
        email = request.form['t4']
        address = request.form['t5']
        command = 'not_found'
        db_connect = pymysql.connect(host=DB_HOST, user=DB_USER, password=DB_PASSWORD, database=DB_NAME, charset='utf8')
        cursor = db_connect.cursor()
        cursor.execute("SELECT username FROM signup WHERE username = %s", (username,))
        row = cursor.fetchone()
        if row:
            command = f"Username {username} already exists"
        else:
            query = """
                INSERT INTO signup (username, password, contact_no, email, address) 
                VALUES (%s, %s, %s, %s, %s)
            """
            cursor.execute(query, (username, password, contact, email, address))
            db_connect.commit()  
            
            if cursor.rowcount == 1:
                command = 'New User Registration Completed'
        
        cursor.close()
        db_connect.close()
        
        return render_template('Register.html', data=command)

@app.route('/UserLoginAction', methods=['GET', 'POST'])
def UserLoginAction():
    if request.method == 'POST':
        global user
        user = request.form['t1']
        password = request.form['t2']
        command = 'none'
        db_connect = pymysql.connect(host=DB_HOST, user=DB_USER, password=DB_PASSWORD, database=DB_NAME, charset='utf8')
        with db_connect:
            cursor = db_connect.cursor()
            cursor.execute("SELECT username, password FROM signup WHERE username = %s AND password = %s", (user, password))
            row = cursor.fetchone()
            if row:
                command = 'success'  
        if command == "success":
            return render_template('UserScreen.html', data="Welcome " + user)
        else:
            return render_template('UserLogin.html', data="Invalid login details")

@app.route('/PredictPrices', methods=['GET', 'POST'])
def PredictPrices():
    global user
    if not user:
        return render_template('UserLogin.html', data="Please login first")
        
    return render_template('PredictPrices.html', data='')

@app.route('/Register', methods=['GET', 'POST'])
def Register():
    return render_template('Register.html', data='')

@app.route('/UserLogin', methods=['GET', 'POST'])
def UserLogin():
    return render_template('UserLogin.html', data='')

@app.route('/', methods=['GET', 'POST'])
def indexx():
    return render_template('index.html', data='')

@app.route('/index', methods=['GET', 'POST'])
def index():
    return render_template('index.html', data='')

@app.route('/Logout')
def Logout():
    session.clear()
    global user
    user = None
    return redirect(url_for('index'))

@app.after_request
def add_header(response):
    response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
    response.headers["Pragma"] = "no-cache"
    response.headers["Expires"] = "0"
    return response

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=int(os.environ.get('PORT', 5000)))










