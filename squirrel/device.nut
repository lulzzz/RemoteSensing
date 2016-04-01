// Reads data from a station and pushes it to an agent
// Agent then pushes the weather data to Wunderground


local rxLEDToggle = 1;  // These variables keep track of rx/tx LED toggling status
local txLEDToggle = 1;

local NOCHAR = -1;

server.log("Device started, impee_id " + hardware.getimpeeid() + " and mac = " + imp.getmacaddress() );

//------------------------------------------------------------------------------------------------------------------------------
// Uart57 for TX/RX
SERIAL <- hardware.uart57;
SERIAL.configure(115200, 8, PARITY_NONE, 1, NO_CTSRTS);

// Set pin1 high for normal operation
// Set pin1 low to reset a standard Arduino
RESET <- hardware.pin1;
//RESET.configure(DIGITAL_OUT); //This causes the board to stick in reset state? Not sure.
RESET.write(1); //Leave Arduino in normal (non-reset) state

// Pin 9 is the yellow LED on the Imp Shield
ACTIVITY <- hardware.pin9;
ACTIVITY.configure(DIGITAL_OUT);
ACTIVITY.write(1);

// Pin 8 is the orange LED
LINK <- hardware.pin8;
LINK.configure(DIGITAL_OUT);
LINK.write(1);

function toggleTxLED()
{
    txLEDToggle = 1 - txLEDToggle;    // toggle the txLEDtoggle variable
    ACTIVITY.write(txLEDToggle);  // TX LED is on pin 8 (active-low)
}

function toggleRxLED()
{
    rxLEDToggle = 1 - rxLEDToggle;    // toggle the rxLEDtoggle variable
    LINK.write(rxLEDToggle);   // RX LED is on pin 8 (active-low)
}

//When the agent detects a midnight cross over, send a reset to arduino
//This resets the cumulative rain and other daily variables
agent.on("sendMidnightReset", function(ignore) {
    server.log("Device midnight reset");
    SERIAL.write("@"); //Special midnight command
});

// Send a character to the Arduino to gather the latest data
// Pass that data onto the Agent for parsing and posting to Wunderground
function checkWeather() {
    
    //Get all the various bits from the Arduino over UART
    server.log("Gathering new weather data");
    
    //Clean out any previous characters in any buffers
    SERIAL.flush();

    //Ping the Arduino with the ! character to get the latest data
    SERIAL.write("!");

    //Wait for initial character to come in
    local counter = 0;
    local result = NOCHAR;
    while(result == NOCHAR)
    {
        result = SERIAL.read(); //Wait for a new character to arrive

        imp.sleep(0.01);
        if(counter++ > 200) //2 seconds
        {
            server.log("Serial timeout error initial");
            return(0); //Bail after 2000ms max wait 
        }
    }
    
    // Collect bytes
    local incomingStream = "";
    while (result != '\n')  // Keep reading until we see a newline
    {
        counter = 0;
        while(result == NOCHAR)
        {
            result = SERIAL.read();
    
            if(result == NOCHAR)
            {
                imp.sleep(0.01);
                if(counter++ > 20) //Wait no more than 20ms for another character
                {
                    server.log("Serial timeout error");
                    return(0); //Bail after 20ms max wait 
                }
            }
        }
        
        incomingStream += format("%c", result);
        toggleTxLED();  // Toggle the TX LED

        result = SERIAL.read(); //Grab the next character in the que
    }
    
    server.log("Arduino read complete");

    ACTIVITY.write(1); //TX LED off

    // Send info to agent, that will in turn push to internet
    agent.send("postToInternet", incomingStream);
    
    //imp.wakeup(10.0, checkWeather);
}

agent.send("ready", true);

SERIAL.configure(9600, 8, PARITY_NONE, 1, NO_CTSRTS); // 9600 baud worked well, no parity, 1 stop bit, 8 data bits

// Start this party going!
checkWeather();

//Power down the imp to low power mode, then wake up after 60 seconds
//Wunderground has a minimum of 2.5 seconds between Rapidfire reports
imp.onidle(function() {
  server.sleepfor(60);
});
