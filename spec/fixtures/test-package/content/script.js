// Capsium Test Package JavaScript

document.addEventListener('DOMContentLoaded', function() {
    console.log('Capsium Test Package loaded successfully!');

    // Get the test button
    const testButton = document.getElementById('testButton');

    // Add click event listener
    testButton.addEventListener('click', function() {
        // Toggle highlight class on paragraphs
        const paragraphs = document.querySelectorAll('p');
        paragraphs.forEach(function(paragraph) {
            paragraph.classList.toggle('highlight');
        });

        // Change button text
        if (testButton.textContent === 'Click Me!') {
            testButton.textContent = 'Reset';
        } else {
            testButton.textContent = 'Click Me!';
        }

        // Log to console
        console.log('Button clicked at: ' + new Date().toLocaleTimeString());
    });

    // Display package info
    const footer = document.querySelector('footer');
    const packageInfo = document.createElement('p');
    packageInfo.textContent = 'Served by Capsium Nginx Reactor';
    footer.appendChild(packageInfo);
});
