#require "azureiothub.class.nut:1.1.0"

// Instantiate a client.
const DEVICE_CONNECT_STRING = "[Hub Connection String]";
client <- iothub.Client.fromConnectionString(DEVICE_CONNECT_STRING);



function sendAzureEvent(json) {
    client.sendEvent(iothub.Message(json), function(err, res) {
        if (err) {
            server.log("sendAzureEvent error: " + err.message + " (" + err.response.statuscode + ")");
        } else {
            server.log("sendAzureEvent successful.");
        }
    });
}

function registerReceiveEvents() {
    client.receive(function(err, message) {
    server.log(format("Received an event: %s", message.getData()));
    client.sendFeedback(iothub.HTTP.FEEDBACK_ACTION_COMPLETE, message);
});
}

registerReceiveEvents();


// This agent gathers data from the device and pushes to Wunderground
// Talks to wunderground rapid fire server (updates of up to once every 10 sec)

// Example incoming serial string from device: 
// $,winddir=270,windspeedmph=0.0,windgustmph=0.0,windgustdir=0,windspdmph_avg2m=0.0,winddir_avg2m=12,windgustmph_10m=0.0,windgustdir_10m=0,humidity=998.0,tempf=-1766.2,rainin=0.00,dailyrainin=0.00,pressure=-999.00,batt_lvl=16.11,light_lvl=3.32,#

local STATION_ID = "[Station Id]";
local STATION_PW = "[Station Password]"; //Note that you must only use alphanumerics in your password. Http post won't work otherwise.

local LOCAL_ALTITUDE_METERS = 50; 

local midnightReset = false; //Keeps track of a once per day cumulative rain reset

local local_hour_offset = 4; 

const MAX_PROGRAM_SIZE = 0x20000;
const ARDUINO_BLOB_SIZE = 128;
//program <- null;


// Handle the device coming online
device.on("ready", function(ready) {
    if (ready){} //send_program();
});


// When we hear something from the device, split it apart and post it
device.on("postToInternet", function(dataString) {
    
    local jsonTable = {};
    
    //server.log("Incoming: " + dataString);
    
    //Break the incoming string into pieces by comma
    a <- mysplit(dataString,',');

    if(a[0] != "$" || a[16] != "#")
    {
        server.log(format("Error: incorrect frame received (%s, %s)", a[0], a[16]));
        server.log(format("Received: %s)", dataString));
        return(0);
    }
    
    //Pull the various bits from the blob
    
    //a[0] is $
    local winddir = a[1];
    local windspeedmph = a[2];
    local windgustmph = a[3];
    local windgustdir = a[4];
    local windspdmph_avg2m = a[5];
    local winddir_avg2m = a[6];
    local windgustmph_10m = a[7];
    local windgustdir_10m = a[8];
    local humidity = a[9];
    local tempf = a[10];
    local rainin = a[11];
    local dailyrainin = a[12];
    local pressure = a[13].tofloat();
    local batt_lvl = a[14];
    local light_lvl = a[15];

    //Correct for negative temperatures. This is fixed in the latest libraries: https://learn.sparkfun.com/tutorials/mpl3115a2-pressure-sensor-hookup-guide
    currentTemp <- mysplit(tempf, '=');
    local badTempf = currentTemp[1].tointeger();
    if(badTempf > 200)
    {
        local tempc = (badTempf - 32) * 5/9; //Convert F to C
        tempc = (tempc<<24)>>24; //Force this 8 bit value into 32 bit variable
        tempc = ~(tempc) + 1; //Take 2s compliment
        tempc *= -1; //Assign negative sign
        tempf = tempc * 9/5 + 32; //Convert back to F
        tempf = "tempf=" + tempf; //put a string on it
    }
    
    currentTemp <- mysplit(tempf, '=');
    jsonTable["tempf"] <- currentTemp[1];
    
    //Correct for humidity out of bounds
    currentHumidity <- mysplit(humidity, '=');
    jsonTable["humidity"] <- currentHumidity[1];
    
    if(currentHumidity[1].tointeger() > 99) {
        humidity = "humidity=99";
        jsonTable["humidity"] <- 99.0;
    }
    if(currentHumidity[1].tointeger() < 0) {
        humidity = "humidity=0";
        jsonTable["humidity"] <- 0.0;
    }

    //Turn Pascal pressure into baromin (Inches Mercury at Altimeter Setting)
    local bar = convertToInHg(pressure);
    local baromin = "baromin=" + bar;
    jsonTable["baromin"] <- bar;
    
    //Calculate a dew point
    currentHumidity <- mysplit(humidity, '=');
    currentTempF <- mysplit(tempf, '=');
    local dpt = calcDewPoint(currentHumidity[1].tointeger(), currentTempF[1].tointeger());
    local dewptf = "dewptf=" + dpt;
    jsonTable["dewptf"] <- dpt;

    //Now we form the large string to pass to wunderground
    local strMainSite = "http://rtupdate.wunderground.com/weatherstation/updateweatherstation.php";

    local strID = "ID=" + STATION_ID;
    local strPW = "PASSWORD=" + STATION_PW;
    
    jsonTable["deviceId"] <- "WeatherStation";

    //Form the current date/time
    //Note: .month is 0 to 11!
    local currentTime = date(time(), 'u');
    
    local azureTime = currentTime.year + format("%02d", currentTime.month + 1) + format("%02d", currentTime.day);
    azureTime += format("%02d", currentTime.hour) + format("%02d", currentTime.min);
    
    
    jsonTable["currentTime"] <- azureTime;
    
    local strCT = currentTime.year + "-" + format("%02d", currentTime.month + 1) + "-" + format("%02d", currentTime.day);
    strCT += "+" + format("%02d", currentTime.hour) + "%3A" + format("%02d", currentTime.min) + "%3A" + format("%02d", currentTime.sec);
    
    strCT = "dateutc=" + strCT;
    
    local kvp = split(winddir, "=");
    jsonTable[kvp[0]] <- kvp[1];
    
    kvp = split(windspeedmph, "=");
    jsonTable[kvp[0]] <- kvp[1];
    
    kvp = split(windgustmph, "=");
    jsonTable[kvp[0]] <- kvp[1];
    
    kvp = split(windgustdir, "=");
    jsonTable[kvp[0]] <- kvp[1];
    
    kvp = split(windspdmph_avg2m, "=");
    jsonTable[kvp[0]] <- kvp[1];
    
    kvp = split(winddir_avg2m, "=");
    jsonTable[kvp[0]] <- kvp[1];
    
    kvp = split(windgustmph_10m, "=");
    jsonTable[kvp[0]] <- kvp[1];
    
    kvp = split(windgustdir_10m, "=");
    jsonTable[kvp[0]] <- kvp[1];
    
    kvp = split(rainin, "=");
    jsonTable[kvp[0]] <- kvp[1];
    
    kvp = split(dailyrainin, "=");
    jsonTable[kvp[0]] <- kvp[1];
    
    local bigString = strMainSite;
    bigString += "?" + strID;
    bigString += "&" + strPW;
    bigString += "&" + strCT;
    bigString += "&" + winddir;
    bigString += "&" + windspeedmph;
    bigString += "&" + windgustmph;
    bigString += "&" + windgustdir;
    bigString += "&" + windspdmph_avg2m;
    bigString += "&" + winddir_avg2m;
    bigString += "&" + windgustmph_10m;
    bigString += "&" + windgustdir_10m;
    bigString += "&" + humidity;
    bigString += "&" + tempf;
    bigString += "&" + rainin;
    bigString += "&" + dailyrainin;
    bigString += "&" + baromin;
    bigString += "&" + dewptf;
    //bigString += "&" + weather;
    //bigString += "&" + clouds;
    bigString += "&" + "softwaretype=BackyardStation"; //Cause we can
    bigString += "&" + "realtime=1"; //You better believe it!
    bigString += "&" + "rtfreq=10"; //Set rapid fire freq to once every 10 seconds
    bigString += "&" + "action=updateraw";

    //server.log("string to send: " + bigString);
    
    //Push to Wunderground
    local request = http.post(bigString, {}, "");
    local response = request.sendsync();
    server.log("Wunderground response = " + response.body);
    server.log(batt_lvl + " " + light_lvl);

    kvp = split(batt_lvl, "=");
    jsonTable[kvp[0]] <- kvp[1];
    
     kvp = split(light_lvl, "=");
    jsonTable[kvp[0]] <- kvp[1];

    // send to Azure
    local json = http.jsonencode(jsonTable);
    sendAzureEvent(json);

    //Check to see if we need to send a midnight reset
    checkMidnight(0);

    server.log("Update complete!");
}); 

//With relative humidity and temp, calculate a dew point
//From: http://ag.arizona.edu/azmet/dewpoint.html
function calcDewPoint(relativeHumidity, tempF) {
    local tempC = (tempF - 32) * 5 / 9.0;

    local L = math.log(relativeHumidity / 100.0);
    local M = 17.27 * tempC;
    local N = 237.3 + tempC;
    local B = (L + (M / N)) / 17.27;
    local dewPoint = (237.3 * B) / (1.0 - B);
    
    //Result is in C
    //Convert back to F
    dewPoint = dewPoint * 9 / 5.0 + 32;

    //server.log("rh=" + relativeHumidity + " tempF=" + tempF + " tempC=" + tempC);
    //server.log("DewPoint = " + dewPoint);
    return(dewPoint);
}

function checkMidnight(ignore) {
    //Check to see if it's midnight. If it is, send @ to Arduino to reset time based variables

    //Get the local time that this measurement was taken
    local localTime = calcLocalTime(); 
    
    //server.log("Local hour = " + format("%c", localTime[0]) + format("%c", localTime[1]));

    if(localTime[0].tochar() == "0" && localTime[1].tochar() == "4")
    {
        if(midnightReset == false)
        {
            server.log("Sending midnight reset");
            midnightReset = true; //We should only reset once
            device.send("sendMidnightReset", 1);
        }
    }
    else {
        midnightReset = false; //Reset our state
    }
}

//Given pressure in pascals, convert the pressure to Altimeter Setting, inches mercury
function convertToInHg(pressure_Pa)
{
    local pressure_mb = pressure_Pa / 100; //pressure is now in millibars, 1 pascal = 0.01 millibars
    
    local part1 = pressure_mb - 0.3; //Part 1 of formula
    local part2 = 8.42288 / 100000.0;
    local part3 = math.pow((pressure_mb - 0.3), 0.190284);
    local part4 = LOCAL_ALTITUDE_METERS / part3;
    local part5 = (1.0 + (part2 * part4));
    local part6 = math.pow(part5, (1.0/0.190284));
    local altimeter_setting_pressure_mb = part1 * part6; //Output is now in adjusted millibars
    local baromin = altimeter_setting_pressure_mb * 0.02953;
    //server.log(format("%s", baromin));
    return(baromin);
}

//From Hugo: http://forums.electricimp.com/discussion/915/processing-nmea-0183-gps-strings/p1
//You rock! Thanks Hugo!
function mysplit(a, b) {
  local ret = [];
  local field = "";
  foreach(c in a) {
      if (c == b) {
          // found separator, push field
          ret.push(field);
          field="";
      } else {
          field += c.tochar(); // append to field
      }
   }
   // Push the last field
   ret.push(field);
   return ret;
}

//Given UTC time and a local offset and a date, calculate the local time
//Includes a daylight savings time calc for the US
function calcLocalTime()
{
    //Get the time that this measurement was taken
    local currentTime = date(time(), 'u');
    local hour = currentTime.hour; //Most of the work will be on the current hour

    //Since 2007 DST starts on the second Sunday in March and ends the first Sunday of November
    //Let's just assume it's going to be this way for awhile (silly US government!)
    //Example from: http://stackoverflow.com/questions/5590429/calculating-daylight-savings-time-from-only-date
    
    //The Imp .month returns 0-11. DoW expects 1-12 so we add one.
    local month = currentTime.month + 1;
    
    local DoW = day_of_week(currentTime.year, month, currentTime.day); //Get the day of the week. 0 = Sunday, 6 = Saturday
    local previousSunday = currentTime.day - DoW;

    local dst = false; //Assume we're not in DST
    if(month > 3 && month < 11) dst = true; //DST is happening!

    //In March, we are DST if our previous Sunday was on or after the 8th.
    if (month == 3)
    {
        if(previousSunday >= 8) dst = true; 
    } 
    //In November we must be before the first Sunday to be dst.
    //That means the previous Sunday must be before the 1st.
    if(month == 11)
    {
        if(previousSunday <= 0) dst = true;
    }

    if(dst == true)
    {
        hour++; //If we're in DST add an extra hour
    }

    //Convert UTC hours to local current time using local_hour
    if(hour < local_hour_offset)
        hour += 24; //Add 24 hours before subtracting local offset
    hour -= local_hour_offset;
    
    local AMPM = "AM";
    if(hour > 12)
    {
        hour -= 12; //Get rid of military time
        AMPM = "PM";
    }
    if(hour == 0) hour = 12; //Midnight edge case

    currentTime = format("%02d", hour) + format("%02d", currentTime.min) + format("%02d", currentTime.sec) +  AMPM;
    //server.log("Local time: " + currentTime);
    return(currentTime);
}

//Given the current year/month/day
//Returns 0 (Sunday) through 6 (Saturday) for the day of the week
//Assumes we are operating in the 2000-2099 century
//From: http://en.wikipedia.org/wiki/Calculating_the_day_of_the_week
function day_of_week(year, month, day)
{

  //offset = centuries table + year digits + year fractional + month lookup + date
  local centuries_table = 6; //We assume this code will only be used from year 2000 to year 2099
  local year_digits;
  local year_fractional;
  local month_lookup;
  local offset;

  //Example Feb 9th, 2011

  //First boil down year, example year = 2011
  year_digits = year % 100; //year_digits = 11
  year_fractional = year_digits / 4; //year_fractional = 2

  switch(month) {
  case 1: 
    month_lookup = 0; //January = 0
    break; 
  case 2: 
    month_lookup = 3; //February = 3
    break; 
  case 3: 
    month_lookup = 3; //March = 3
    break; 
  case 4: 
    month_lookup = 6; //April = 6
    break; 
  case 5: 
    month_lookup = 1; //May = 1
    break; 
  case 6: 
    month_lookup = 4; //June = 4
    break; 
  case 7: 
    month_lookup = 6; //July = 6
    break; 
  case 8: 
    month_lookup = 2; //August = 2
    break; 
  case 9: 
    month_lookup = 5; //September = 5
    break; 
  case 10: 
    month_lookup = 0; //October = 0
    break; 
  case 11: 
    month_lookup = 3; //November = 3
    break; 
  case 12: 
    month_lookup = 5; //December = 5
    break; 
  default: 
    month_lookup = 0; //Error!
    return(-1);
  }

  offset = centuries_table + year_digits + year_fractional + month_lookup + day;
  //offset = 6 + 11 + 2 + 3 + 9 = 31
  offset %= 7; // 31 % 7 = 3 Wednesday!

  return(offset); //Day of week, 0 to 6

  //Example: May 11th, 2012
  //6 + 12 + 3 + 1 + 11 = 33
  //5 = Friday! It works!

   //Devised by Tomohiko Sakamoto in 1993, it is accurate for any Gregorian date:
   /*t <- [ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4];
   if(month < 3) year--;
   //year = month < 3;
 return (year + year/4 - year/100 + year/400 + t[month-1] + day) % 7;
   //return 4;
   */
}
