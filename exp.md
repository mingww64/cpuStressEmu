# Experiment Details

## 1. Objective
This document explains the process and parameters for doing an automated CPU cooling performance test. The main goal was to check out the thermal characteristics of the CPU cooling solution under different power limits (Package Power Target - PPT) while keeping the computational load the same. One of the main things that came out of this was the creation and testing of a thermal resistance model.

## 2. System and Hardware

```
[nix-shell:~/cpuStressEmu]$ neofetch 
          ▗▄▄▄       ▗▄▄▄▄    ▄▄▄▖
          ▜███▙       ▜███▙  ▟███▛
           ▜███▙       ▜███▙▟███▛
            ▜███▙       ▜██████▛              cpuStressEmu@phys23 
     ▟█████████████████▙ ▜████▛     ▟▙        --------------- 
    ▟███████████████████▙ ▜███▙    ▟██▙       OS: NixOS 25.11 (Xantusia) x86_64 
           ▄▄▄▄▖           ▜███▙  ▟███▛       Host: ASRock X300M-STX 
          ▟███▛             ▜██▛ ▟███▛        Kernel: 6.14.7-zen1 
         ▟███▛               ▜▛ ▟███▛         Shell: bash 5.2.37  
▟███████████▛                  ▟██████████▙   GPU: AMD ATI Radeon Vega Series / Radeon Vega Mobile Series  
▜██████████▛                  ▟███████████▛   CPU: AMD Ryzen 5 PRO 4650G with Radeon Graphics (12) @ 4.309GHz
      ▟███▛ ▟▙               ▟███▛            
     ▟███▛ ▟██▙             ▟███▛             
    ▟███▛  ▜███▙           ▝▀▀▀▀              
    ▜██▛    ▜███▙ ▜██████████████████▛         
     ▜▛     ▟████▙ ▜████████████████▛          
           ▟██████▙       ▜███▙                
          ▟███▛▜███▙       ▜███▙              
         ▟███▛  ▜███▙       ▜███▙             
         ▝▀▀▀    ▀▀▀▀▘       ▀▀▀▘
```

## 3. Configuration & Control Software
The experiment was orchestrated using a BASH script [`emu.sh`](https://github.com/mingww64/cpuStressEmu/blob/main/emu.sh).

### 3.1. Sensor Monitoring
* **CPU Temperature:**
    * Read Command: `ryzen_monitor --test-export`
    * Line Identifier (grep pattern): `cpu_thm`
    * Field Name: `cpu_thm`
* **CPU Power:**
    * Read Command: `ryzen_monitor --test-export`
    * Line Identifier (grep pattern): `cpu_ppt`
    * Field Name: `cpu_ppt`
* **CPU Fan RPM:**
    * Path: `/sys/class/hwmon/hwmon3/fan2_input`

### 3.2. CPU Power Control (PPT)
* **PPT Control Enabled:** Yes
* **Base Command for Setting PPT:** `ryzen_monitor`
* **Argument Format for Setting PPT:** `--set-ppt=`
* **PPT Values Tested (Watts):** 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55.

### 3.3. CPU Load Generation
* **Load Generation Enabled:** Yes, `mprime` run in the background.
* **`mprime` Thread Count:** 6 threads (with hyperthearding, used for all PPT tests).

## 4. Test Protocol
* **Warm-up Duration:** 30 seconds (default).
* **Measurement Duration per Test:** 30 seconds.
* **Cool-down Duration after each Test:** 0 seconds. *Practically unnecessary as PPTs are incremental.*
* **Output CSV File Name:** `cpu_cooling_data_controlled.csv`.
* **Sampling Interval:** 1 second (default).
* **Ambient Temperature (at start of test sequence):** 22.8 °C.

## 5. Procedure Summary

1.  Set the CPU PPT limit using the configured `ryzen_monitor` command.
2.  If enabled, start `mprime` with the specified number of threads.
3.  Wait for the warm-up duration to allow temperatures to stabilize.
4.  During the measurement duration, periodically (based on sampling interval):
    * Read CPU temperature $T_{case}$.
    * Read CPU power $P_{cpu}$.
    * Read CPU fan RPM.
    * Record these values along with the ambient temperature $T_{ambient}$ and current timestamp to the CSV file.
5.  Stop `mprime` (if running).
6.  Wait for the cool-down duration (if any).
7.  Repeat for the next PPT value.
8.  After all tests, reset the CPU PPT to the specified reset value.

## 6. Thermal Resistance Model Development

### 6.1. Thermal Resistance Calculation
For each data point collected, the overall thermal resistance $R_{th}$ of the cooling system was calculated using the fundamental relationship:

$R_{th} = (T_{case} - T_{ambient}) / P_{cpu}$

Where $T_{case}$ is the CPU temperature, $T_{ambient}$ is the intake air temperature, and $P_{cpu}$ is the actual CPU power consumed.

### 6.2. Physics-Informed Model Structure
A physics-informed model was chosen to describe the relationship between thermal resistance and CPU fan RPM (airflow). The model structure is:

$R_{th}(RPM) = R_{fixed} + C / RPM^n$

Where:
* **$R_{fixed}$**: Represents the sum of thermal resistances that are largely independent of airflow, such as conduction through Thermal Interface Materials (TIMs), the CPU's Integrated Heat Spreader (IHS), and the cooler's baseplate.
* **$C / RPM^n$**: Represents the convective thermal resistance from the heatsink fins to the air. This component is highly dependent on airflow.
    * **$C$**: A constant related to the heat sink geometry, material properties, and fluid (air) properties.
    * **$n$**: An exponent characterizing the relationship between airflow velocity (assumed proportional to RPM) and the convective heat transfer coefficient. Theoretical values for $n$ often range from 0.5 (laminar flow) to 0.8 (turbulent flow).

### 6.3. Model Fitting
The model parameters $R_{fixed}$, $C$, and $n$ were determined by fitting the model equation to the experimentally derived $RPM$, $R_{th}$ data points. This was achieved using a non-linear least squares regression algorithm (specifically, `scipy.optimize.curve_fit` in the Python [analysis](https://github.com/mingww64/cpuStressEmu/blob/main/fit.py)).

The fitted parameters obtained from the analysis were approximately:
* $R_{fixed} \approx 0.0000 \, °C/W$
* $C \approx 12.0157$
* $n \approx 0.3467$

This resulted in the specific model equation:

$R_{th}(RPM) \approx 0.0000 + 12.0157 / RPM^{0.3467}$

$R_{th}(RPM) \approx 12.0157 / RPM^{0.3467}$

The value of $R_{fixed}$ being close to zero suggests that, for this specific dataset and cooler, the airflow-dependent convective resistance is the dominant factor in the total thermal resistance, or that the fixed resistances are very small and effectively absorbed into the convective term by the fitting process. The exponent $n \approx 0.35$ indicates the sensitivity of the cooler's performance to changes in fan speed.
