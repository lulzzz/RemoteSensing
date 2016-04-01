//*********************************************************
//
// Copyright (c) Microsoft. All rights reserved.
// This code is licensed under the MIT License (MIT).
// THIS CODE IS PROVIDED *AS IS* WITHOUT WARRANTY OF
// ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING ANY
// IMPLIED WARRANTIES OF FITNESS FOR A PARTICULAR
// PURPOSE, MERCHANTABILITY, OR NON-INFRINGEMENT.
//
//*********************************************************


using Microsoft.Maker.RemoteWiring;
using Microsoft.Maker.Serial;
using System;
using System.Diagnostics;
using Windows.Devices.Enumeration;
using Windows.UI.Xaml;
using Windows.UI.Xaml.Controls;

using GT = GHIElectronics.UWP.GadgeteerCore;
using GTMB = GHIElectronics.UWP.Gadgeteer.Mainboards;
using GTMO = GHIElectronics.UWP.Gadgeteer.Modules;

namespace Winiot.GadgeteerSensors
{
    public sealed partial class Polling : Page
    {
        private GTMB.FEZCream mainboard;
        private GTMO.LightSense lightSensor;
        private GTMO.TempHumidSI70 tempSensor;

        private RemoteDevice arduino;
        private IStream arduinoConnection;

        private const int OnboardLedPin = 13; 
        private const int PollSensorPin = 3;


        // A pointer back to the main page.
        MainPage rootPage = MainPage.Current;

        public Polling()
        {
            this.InitializeComponent();
            this.Setup();
        }

        private async void Setup()
        {
            try
            {
                rootPage.NotifyUser("Establishing sensor connectivity", NotifyType.StatusMessage);

                this.mainboard = await GT.Module.CreateAsync<GTMB.FEZCream>();
                this.lightSensor = await GT.Module.CreateAsync<GTMO.LightSense>(this.mainboard.GetProvidedSocket(6));
                this.tempSensor = await GT.Module.CreateAsync<GTMO.TempHumidSI70>(this.mainboard.GetProvidedSocket(8));

                // serial connection via XBee modules
                arduinoConnection = new UsbSerial("0403", "6001");

                //Begin connection
                arduinoConnection.begin(57600, SerialConfig.SERIAL_8N1);

                //Attach event handlers
                arduinoConnection.ConnectionEstablished += ArduinoConnectionEstablished;
                arduinoConnection.ConnectionFailed += ArduinoConnectionFailed;

                // instantiate remote device
                arduino = new RemoteDevice(arduinoConnection);
                arduino.StringMessageReceived += ArduinoStringMessageReceived;
                rootPage.NotifyUser("Sensors connected successfully!", NotifyType.StatusMessage);
            }
            catch (Exception e)
            {
                rootPage.NotifyUser("Error connecting to sensors", NotifyType.ErrorMessage);
            }
        }


        private void ArduinoConnectionEstablished()
        {
            Debug.WriteLine("Arduino connection established");           
        }

        private void ArduinoStringMessageReceived(string message)
        {
            Debug.WriteLine(message);
            // sensor data string processing here
        }

        private void ArduinoConnectionFailed(string message)
        {
            rootPage.NotifyUser("Arduino connection failed: " + message, NotifyType.ErrorMessage);
        }

        /// <summary>
        /// This is the dispatcher callback.
        /// </summary>
        /// <param name="sender"></param>
        /// <param name="args"></param>
        private void GetData(object sender, RoutedEventArgs e)
        {
            if (tempSensor != null & lightSensor != null)
            {
                var temp2 = tempSensor.TakeMeasurement();
                var light = lightSensor.GetReading();

                double temp = temp2.TemperatureFahrenheit;
                double humidity = temp2.RelativeHumidity;
                Temperature.Text = temp.ToString("F1");
                Humidity.Text = humidity.ToString("F1");
                Light.Text = light.ToString("F2");
            }
            else
            {
                rootPage.NotifyUser("Error getting data from sensors", NotifyType.ErrorMessage);
            }
        }

        /// <summary>
        /// This is the dispatcher callback.
        /// </summary>
        /// <param name="sender"></param>
        /// <param name="args"></param>
        private void GetRemoteData(object sender, RoutedEventArgs e)
        {
            arduino.digitalWrite(OnboardLedPin, PinState.HIGH);
            PollRemoteSensor(true);
            
            arduino.digitalWrite(OnboardLedPin, PinState.HIGH);
        }

        // turn data collection on/off
        // pin state is high on start, so pull low to turn this on remotely
        private void PollRemoteSensor(bool on) {
            //arduino.pinMode(PollSensorPin, PinMode.OUTPUT); //Set the pin to output
            PinState pinState = PinState.LOW;
            if (on) { pinState = PinState.HIGH; }
            arduino.digitalWrite(PollSensorPin, pinState);
        }
    }
}
