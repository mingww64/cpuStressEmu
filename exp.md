# Experiment Details

## 1. Objective
This document outlines the methodology and parameters used for an automated CPU cooling performance test. The primary goal was to evaluate the thermal characteristics of the CPU cooling solution under various controlled power limits (Package Power Target - PPT) while under a consistent computational load. A key outcome was the development and validation of a thermal resistance model.

## 2. System and Hardware (Inferred)
* **CPU:** An AMD Ryzen processor (implied by `ryzen_monitor` and `ryzenadj` tools).
* **Cooling Solution:** The specific CPU cooler is not detailed in this script log, but its performance is the subject of the test (previously identified as Noctua NH-L9a-AM4).
* **Operating System:** A Linux-based system (implied by BASH script and `/sys/` paths).

## 3. Configuration & Control Software
The experiment was orchestrated using a BASH script (`emu.sh`).

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
* **`mprime` Thread Count:** 6 threads (used for all PPT tests).
    * *Note: The script assumes `mprime` (e.g., `prime.txt`) is pre-configured for the desired test type, such as Small FFTs, to maximize heat output.*

## 4. Test Protocol
* **Warm-up Duration:** 30 seconds (default).
* **Measurement Duration per Test:** 30 seconds.
* **Cool-down Duration after each Test:** 0 seconds. *practically unnecessary as PPTs are incremental.*
* **Output CSV File Name:** `cpu_cooling_data_controlled.csv`.
* **Sampling Interval:** 1 second (default).
* **Ambient Temperature (at start of test sequence):** 22.8 °C.

## 5. Procedure Summary
The script automated the following sequence for each specified PPT value:
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
This structured approach ensures consistent data collection across a range of power loads.

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
The model parameters $R_{fixed}$, $C$, and $n$ were determined by fitting the model equation to the experimentally derived $RPM$, $R_{th}$ data points. This was achieved using a non-linear least squares regression algorithm (specifically, `scipy.optimize.curve_fit` in the Python analysis).

The fitted parameters obtained from the analysis `.csv` were approximately:
* $R_{fixed} \approx 0.0000 \, °C/W$
* $C \approx 12.0157$
* $n \approx 0.3467$

This resulted in the specific model equation:

$R_{th}(RPM) \approx 0.0000 + 12.0157 / RPM^{0.3467}$

The value of $R_{fixed}$ being close to zero suggests that, for this specific dataset and cooler, the airflow-dependent convective resistance is the dominant factor in the total thermal resistance, or that the fixed resistances are very small and effectively absorbed into the convective term by the fitting process. The exponent $n \approx 0.35$ indicates the sensitivity of the cooler's performance to changes in fan speed.

## 7. Error Analysis and Limitations

### 7.1. Measurement Errors
* **Sensor Accuracy:** The accuracy of the temperature sensors (CPU, ambient), power sensors (`ryzen_monitor`), and fan RPM sensor can introduce uncertainties. Calibration data for these sensors was not available.
* **Ambient Temperature Fluctuations:** While an initial ambient temperature was recorded, it might have fluctuated during the extended test sequence. The script uses a single initial ambient temperature for all calculations if not updated per data point. Ideally, $T_{ambient}$ should be the air temperature immediately at the cooler's intake, which can be influenced by system exhaust if not well-isolated.
* **Sensor Reading Lag:** There might be slight delays or differences in response times between the various sensors.
* **Dynamic CPU Behavior:** CPU power and temperature can fluctuate rapidly. The 1-second sampling interval might not capture all instantaneous peaks or valleys, leading to averaged readings.

### 7.2. Systematic Errors & Experimental Control
* **Load Consistency:** While `mprime` provides a heavy load, its exact power draw can vary slightly depending on CPU state, background OS processes, and the specific test vector being executed.
* **Background Processes:** Other OS or user processes could consume CPU resources, affecting power draw and temperature, although `mprime` with multiple threads typically dominates.
* **Thermal Interface Material (TIM):** The quality and consistency of the TIM application between the CPU IHS and the cooler baseplate significantly impact thermal transfer. Variations here are a common source of discrepancy.
* **Cooler Mounting Pressure:** Inconsistent or inadequate mounting pressure can lead to higher contact resistance and reduced cooling performance.
* **Case Airflow:** The overall airflow within the PC case (if used) can affect the cooler's intake temperature and efficiency. This experiment focuses on the cooler itself, but its performance is coupled with the system environment.

### 7.3. Modeling Errors & Assumptions
* **Model Simplification:** The $R_{th}(RPM) = R_{fixed} + C / RPM^n$ model is a common and useful simplification but does not capture all complex heat transfer physics (e.g., detailed fin efficiency, non-uniform airflow, radiation).
* **RPM to Airflow Proportionality:** The model assumes a direct power-law relationship between fan RPM and effective airflow velocity over the fins. The actual relationship can be more complex due to fan design and system impedance.
* **Parameter Fitting:** The fitting process finds the best parameters for the given dataset but doesn't guarantee these are the "true" physical constants if the model form is not perfectly representative or if data is noisy. The low $R_{fixed}$ value is an example of how the fit optimizes for the observed data.
* **Extrapolation:** The model is most reliable within the range of RPMs tested. Extrapolating far outside this range (e.g., to very low or very high RPMs not covered by data) may lead to inaccurate predictions.

### 7.4. Data Collection Script Limitations
* **Synchronization:** While readings are taken in quick succession, they are not perfectly simultaneous. `ryzen_monitor` might provide internally synchronized CPU power and temperature, which is beneficial.
* **`mprime` Control:** The script starts and stops `mprime`. Ensuring `mprime` reaches a stable load state within the warm-up period is important.

Addressing these potential error sources through careful experimental setup, sensor calibration (if possible), and awareness of model limitations is crucial for robust thermal analysis.